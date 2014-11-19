{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

module Network.Wai.Handler.Warp.HTTP2 (isHTTP2, http2) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (when, unless)
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
        let enqout = enqueueRsp ctx ii settings
            mkreq = mkRequest settings addr
        tid <- forkIO $ frameSender conn ii ctx
        let rsp = settingsFrame id []
        atomically $ writeTQueue (outputQ ctx) rsp
        frameReceiver conn ctx mkreq enqout src app `E.finally` killThread tid
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
