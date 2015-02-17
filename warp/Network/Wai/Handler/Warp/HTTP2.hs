{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

module Network.Wai.Handler.Warp.HTTP2 (isHTTP2, http2) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (when, unless, replicateM, void, forever)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Network.HTTP2
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Handler.Warp.HTTP2.Receiver
import Network.Wai.Handler.Warp.HTTP2.Request
import Network.Wai.Handler.Warp.HTTP2.Response
import Network.Wai.Handler.Warp.HTTP2.Sender
import Network.Wai.Handler.Warp.HTTP2.Types
import qualified Network.Wai.Handler.Warp.Settings as S (Settings)
import Network.Wai.Handler.Warp.Types

----------------------------------------------------------------

http2 :: Connection -> InternalInfo -> SockAddr -> Transport -> S.Settings -> Source -> Application -> IO ()
http2 conn ii addr transport settings src app = do
    checkTLS
    ok <- checkPreface
    when ok $ do
        ctx <- newContext
        let enQResponse = enqueueRsp ctx ii settings
            mkreq = mkRequest settings addr
        tid <- forkIO $ frameReceiver ctx mkreq src
        -- fixme: 6 is hard-coded
        tids <- replicateM 6 $ forkIO $ worker ctx app enQResponse
        -- fixme: 100 is hard-coded
        let rsp = settingsFrame id [(SettingsMaxConcurrentStreams,100)]
        atomically $ writeTQueue (outputQ ctx) rsp
        -- frameSender is the main thread because it ensures to send
        -- a goway frame.
        frameSender conn ii ctx `E.finally` mapM_ killThread (tid:tids)
  where
    checkTLS = case transport of
        TCP -> goaway conn InadequateSecurity "Weak TLS"
        tls -> unless (tls12orLater tls) $ goaway conn InadequateSecurity "Weak TLS"
    tls12orLater tls = tlsMajorVersion tls == 3 && tlsMinorVersion tls >= 3
    checkPreface = do
        bytes <- readSource src
        if BS.length bytes < connectionPrefaceLength then do
            goaway conn ProtocolError "Preface mismatch"
            return False
          else do
            let (preface, frames) = BS.splitAt connectionPrefaceLength bytes
            if connectionPreface /= preface then do
                goaway conn ProtocolError "Preface mismatch"
                return False
              else do
                leftoverSource src frames
                return True

-- connClose must not be called here since Run:fork calls it
goaway :: Connection -> ErrorCodeId -> ByteString -> IO ()
goaway Connection{..} etype debugmsg = connSendAll bytestream
  where
    bytestream = goawayFrame (toStreamIdentifier 0) etype debugmsg

worker :: Context -> Application -> EnqRsp -> IO ()
worker Context{..} app enQResponse = forever $ do
    (sid, req) <- atomically $ readTQueue inputQ
    let stid = fromStreamIdentifier sid
    void $ app req $ enQResponse stid
