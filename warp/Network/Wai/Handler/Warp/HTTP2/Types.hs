{-# LANGUAGE OverloadedStrings #-}

module Network.Wai.Handler.Warp.HTTP2.Types where

import Control.Concurrent.STM
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef)
import qualified Data.IntMap as M
import Data.IntMap.Strict (IntMap)
import qualified Network.HTTP.Types as H
import Network.Wai.Handler.Warp.Types

import Network.HTTP2
import Network.HPACK

----------------------------------------------------------------

http2ver :: H.HttpVersion
http2ver = H.HttpVersion 2 0

isHTTP2 :: Transport -> Bool
isHTTP2 TCP = False
isHTTP2 tls = useHTTP2
  where
    useHTTP2 = case tlsNegotiatedProtocol tls of
        Nothing    -> False
        Just proto -> "h2-" `BS.isPrefixOf` proto

----------------------------------------------------------------

data Context = Context {
    http2settings :: IORef Settings
  -- fixme: clean up for frames whose end stream do not arrive
  , streamTable :: IORef (IntMap Stream)
  , continued :: IORef (Maybe StreamIdentifier)
  , currentStreamId :: IORef Int
  , outputQ :: TQueue ByteString
  , encodeDynamicTable :: IORef DynamicTable
  , decodeDynamicTable :: IORef DynamicTable
  }

----------------------------------------------------------------

newContext :: IO Context
newContext = do
    st <- newIORef defaultSettings
    tbl <- newIORef M.empty
    cnt <- newIORef Nothing
    csi <- newIORef 0
    outQ <- newTQueueIO
    eht <- newDynamicTableForEncoding 4096 >>= newIORef
    dht <- newDynamicTableForDecoding 4096 >>= newIORef
    return $ Context st tbl cnt csi outQ eht dht

----------------------------------------------------------------

data Stream = Idle
            | Continued [ByteStream] Bool
            | NoBody HeaderList
            | HasBody HeaderList
            | Body (TQueue ByteString)
            | HalfClosed

instance Show Stream where
    show Idle            = "Idle"
    show (Continued _ _) = "Continued"
    show (NoBody  _)     = "NoBody"
    show (HasBody _)     = "HasBody"
    show (Body _)        = "Body"
    show HalfClosed      = "HalfClosed"
