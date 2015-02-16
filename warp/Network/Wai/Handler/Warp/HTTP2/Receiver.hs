{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

module Network.Wai.Handler.Warp.HTTP2.Receiver (frameReceiver) where

import Control.Concurrent (forkIO, takeMVar)
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (when, unless, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IORef (readIORef, writeIORef, modifyIORef)
import qualified Data.IntMap as M
import Network.Wai
import Network.Wai.Handler.Warp.Types

import Network.HTTP2
import Network.HPACK

import Network.Wai.Handler.Warp.HTTP2.Types
import Network.Wai.Handler.Warp.HTTP2.Sender
import Network.Wai.Handler.Warp.HTTP2.Request
import Network.Wai.Handler.Warp.HTTP2.Response

----------------------------------------------------------------

frameReceiver :: Context -> MkReq -> EnqRsp -> Source -> Application -> IO ()
frameReceiver ctx@Context{..} mkreq enqout src app =
    E.handle sendGoaway loop `E.finally` takeMVar wait
  where
    sendGoaway (ConnectionError err msg) = do
        csid <- readIORef currentStreamId
        let rsp = goawayFrame (toStreamIdentifier csid) err msg
        atomically $ do
            writeTQueue outputQ rsp
            writeTQueue outputQ ""
    sendGoaway _                         = return ()

    sendReset err sid = do
        let rsp = resetFrame err sid
        atomically $ writeTQueue outputQ rsp

    loop = do
        hd <- readBytes frameHeaderLength
        if BS.null hd then
            atomically $ writeTQueue outputQ ""
          else do
            let (typ,header@FrameHeader{..}) = decodeFrameHeader hd
            when (isResponse streamId) $ E.throwIO $ ConnectionError ProtocolError "stream id should be odd"
            cont <- guardError typ header
            when cont loop

    guardError (FrameUnknown _) FrameHeader{..} = do
        mx <- readIORef continued
        case mx of
            Nothing -> do
                -- ignoring unknow frame
                consume payloadLength
                return True
            Just _  -> E.throwIO $ ConnectionError ProtocolError "stream id should be odd"
    guardError FramePushPromise _ =
        E.throwIO $ ConnectionError ProtocolError "push promise is not allowed"
    guardError ftyp header@FrameHeader{..} = do
        settings <- readIORef http2settings
        case checkFrameHeader settings ftyp header of
            Just h2err -> case h2err of
                StreamError err sid -> do
                    sendReset err sid
                    consume payloadLength
                    return True
                connErr -> E.throwIO connErr
            Nothing -> do
                ex <- E.try $ controlOrStream ftyp header
                case ex of
                    Left (StreamError err sid) -> do
                        sendReset err sid
                        return True
                    Left connErr -> E.throw connErr
                    Right cont -> return cont

    controlOrStream ftyp header@FrameHeader{..}
      | isControl streamId = do
          pl <- readBytes payloadLength
          control ftyp header pl ctx
      | otherwise = do
          checkContinued
          let stid = fromStreamIdentifier streamId
          strm <- getStream
          -- fixme: DataFrame loop
          pl <- readBytes payloadLength
          strm' <- stream ftyp header pl ctx strm
          case strm' of
              NoBody hdr -> do
                  resetContinued
                  case validateHeadrs hdr of
                      Just vh -> do
                          register stid HalfClosed
                          let req = mkreq vh (return "")
                          -- fixme: ensuring killing this thread
                          void $ forkIO $ void $ app req $ enqout stid
                      Nothing -> E.throwIO $ StreamError ProtocolError streamId
              HasBody hdr -> do
                  resetContinued
                  case validateHeadrs hdr of
                      Just vh -> do
                          q <- newTQueueIO
                          register stid (Body q)
                          readQ <- newReadBody q
                          bodySource <- mkSource readQ
                          let req = mkreq vh (readSource bodySource)
                          -- fixme: ensuring killing this thread
                          void $ forkIO $ void $ app req $ enqout stid
                      Nothing -> E.throwIO $ StreamError ProtocolError streamId
              s@(Continued _ _) -> do
                  setContinued
                  register stid s
              s -> do
                  resetContinued
                  register stid s
                  print s -- fixme
          return True
       where
         -- fixme: attomic?
         register k v = modifyIORef streamTable $ \m -> M.insert k v m
         setContinued = writeIORef continued (Just streamId)
         resetContinued = writeIORef continued Nothing
         checkContinued = do
             mx <- readIORef continued
             case mx of
                 Nothing  -> return ()
                 Just sid
                   | sid == streamId && ftyp == FrameContinuation -> return ()
                   | otherwise -> E.throwIO $ ConnectionError ProtocolError "continuation frame must follow"
         getStream = do
             let stid = fromStreamIdentifier streamId
             csid <- readIORef currentStreamId
             when (ftyp == FrameHeaders) $
               if stid <= csid then
                   E.throwIO $ ConnectionError ProtocolError "stream identifier must not decrease"
                 else
                   writeIORef currentStreamId stid
             m0 <- readIORef streamTable
             case M.lookup stid m0 of
                 Just strm0 -> return strm0
                 Nothing -> do
                     when (ftyp `notElem` [FrameHeaders,FramePriority]) $
                         E.throwIO $ ConnectionError ProtocolError "this frame is not allowed in an idel stream"
                     return Idle

    consume = void . readBytes

    readBytes len = do
        bs0 <- readSource src
        let len0 = BS.length bs0
        if len0 == 0 then
            return bs0 -- EOF
          else if len0 >= len then do
            let (!frame,!left0) = BS.splitAt len bs0
            leftoverSource src left0
            return frame
          else do
            bs1 <- readSource src
            let len1 = BS.length bs1
            if len0 + len1 >= len then do
                let (!bs1',!left1) = BS.splitAt (len - len0) bs1
                leftoverSource src left1
                return $ BS.append bs0 bs1'
              else
                E.throwIO $ ConnectionError FrameSizeError "not enough frame size"

----------------------------------------------------------------

control :: FrameTypeId -> FrameHeader -> ByteString -> Context -> IO Bool
control FrameSettings header@FrameHeader{..} bs Context{..} = do
    let SettingsFrame alist = decodeSettingsFrame header bs
    case checkSettingsList alist of
        Just x  -> E.throwIO x
        Nothing -> return ()
    unless (testAck flags) $ do
        modifyIORef http2settings $ \old -> updateSettings old alist
        let rsp = settingsFrame setAck []
        atomically $ writeTQueue outputQ rsp
    return True

control FramePing FrameHeader{..} bs Context{..} =
    if testAck flags then
        E.throwIO $ ConnectionError ProtocolError "the ack flag of this ping frame must not be set"
      else do
        let rsp = pingFrame bs
        atomically $ writeTQueue outputQ rsp
        return True

control FrameGoAway _ _ Context{..} = do
    atomically $ writeTQueue outputQ ""
    return False

control FrameWindowUpdate header@FrameHeader{..} bs Context{..} = do
    let WindowUpdateFrame wsi = decodeWindowUpdateFrame header bs
    -- fixme: valid case
    when (wsi == 0) $
        E.throwIO $ ConnectionError ProtocolError "window increment size must not be 0"
    return True

control _ _ _ _ =
    -- must not reach here
    return False

----------------------------------------------------------------

stream :: FrameTypeId -> FrameHeader -> ByteString -> Context -> Stream -> IO Stream
stream FrameHeaders header@FrameHeader{..} bs ctx Idle = do
    let HeadersFrame _ frag = decodeHeadersFrame header bs
        endOfStream = testEndStream flags
        endOfHeader = testEndHeader flags
    if endOfHeader then do
        hdr <- decodeHeaderBlock frag ctx
        return $ if endOfStream then NoBody hdr else HasBody hdr
      else
        return $ Continued [frag] endOfStream

stream FrameData header@FrameHeader{..} bs _ s@(Body q) = do
    let DataFrame body = decodeDataFrame header bs
        endOfStream = testEndStream flags
    atomically $ writeTQueue q body
    if endOfStream then do
        atomically $ writeTQueue q ""
        return HalfClosed
      else
        return s

stream FrameContinuation FrameHeader{..} frag ctx (Continued rfrags endOfStream) = do
    let endOfHeader = testEndHeader flags
        rfrags' = frag : rfrags
    if endOfHeader then do
        let hdrblk = BS.concat $ reverse rfrags'
        hdr <- decodeHeaderBlock hdrblk ctx
        return $ if endOfStream then NoBody hdr else HasBody hdr
      else
        return $ Continued rfrags' endOfStream

stream FrameContinuation _ _ _ _ = E.throwIO $ ConnectionError ProtocolError "continue frame cannot come here"

stream FrameWindowUpdate header@FrameHeader{..} bs Context{..} s = do
    let WindowUpdateFrame wsi = decodeWindowUpdateFrame header bs
    -- fixme: valid case
    when (wsi == 0) $
        E.throwIO $ StreamError ProtocolError streamId
    return s

-- this ordering is important
stream _ _ _ _ (Continued _ _) = E.throwIO $ ConnectionError ProtocolError "an illegal frame follows header/continuation frames"
stream FrameData FrameHeader{..} _ _ _ = E.throwIO $ StreamError StreamClosed streamId
stream _ FrameHeader{..} _ _ _ = E.throwIO $ StreamError ProtocolError streamId

----------------------------------------------------------------

decodeHeaderBlock :: HeaderBlockFragment -> Context -> IO HeaderList
decodeHeaderBlock hdrblk Context{..} = do
    hdrtbl <- readIORef decodeDynamicTable
    (hdrtbl', hdr) <- decodeHeader hdrtbl hdrblk `E.onException` cleanup
    writeIORef decodeDynamicTable hdrtbl'
    return hdr
  where
    cleanup = E.throwIO $ ConnectionError CompressionError "cannot decompress the header"
