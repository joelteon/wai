{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Handler.Warp.HTTP2.Sender where

import Control.Concurrent.STM
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Network.HTTP2
import Network.Wai.Handler.Warp.HTTP2.Types
import qualified Network.Wai.Handler.Warp.Timeout as T
import Network.Wai.Handler.Warp.Types

----------------------------------------------------------------

goaway :: Connection -> ErrorCodeId -> ByteString -> IO ()
goaway Connection{..} etype debugmsg = do
    let einfo = encodeInfo id 0
        frame = GoAwayFrame (toStreamIdentifier 0) etype debugmsg
        bytestream = encodeFrame einfo frame
    connSendAll bytestream
    -- connClose must not be called here since Run:fork calls it

reset :: Connection -> ErrorCodeId -> StreamIdentifier -> IO ()
reset Connection{..} etype sid = do
    let einfo = encodeInfo id $ fromStreamIdentifier sid
        frame = RSTStreamFrame etype
        bytestream = encodeFrame einfo frame
    connSendAll bytestream

----------------------------------------------------------------

settingsFrame :: (FrameFlags -> FrameFlags) -> SettingsList -> ByteString
settingsFrame func alist = encodeFrame einfo $ SettingsFrame alist
  where
    einfo = encodeInfo func 0

pingFrame :: ByteString -> ByteString
pingFrame bs = encodeFrame einfo $ PingFrame bs
  where
    einfo = encodeInfo setAck 0

----------------------------------------------------------------

-- fixme: packing bytestrings
frameSender :: Connection -> InternalInfo -> Context -> IO ()
frameSender Connection{..} InternalInfo{..} Context{..} = loop
  where
    loop = do
        cont <- readQ >>= send
        T.tickle threadHandle
        when cont loop
    readQ = atomically $ readTQueue outputQ
    send bs
      -- "" is EOF. Even if payload is "", its header is NOT "".
      | BS.length bs == 0 = return False
      | otherwise         = do
        -- fixme: connSendMany
        connSendAll bs
        return True
