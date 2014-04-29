{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ViewPatterns      #-}
module Network.HTTP.Client.Headers
    ( parseStatusHeaders
    ) where

import           Control.Applicative            ((<$>), (<*>))
import           Control.Exception              (throwIO)
import           Control.Monad
import qualified Data.ByteString                as S
import qualified Data.ByteString.Char8          as S8
import qualified Data.CaseInsensitive           as CI
import           Network.HTTP.Client.Connection
import           Network.HTTP.Client.Types
import           Network.HTTP.Types
import Data.Word (Word8)

charLF, charCR, charSpace, charColon, charPeriod :: Word8
charLF = 10
charCR = 13
charSpace = 32
charColon = 58
charPeriod = 46


parseStatusHeaders :: Connection -> IO StatusHeaders
parseStatusHeaders conn = do
    (status, version) <- getStatusLine
    headers <- parseHeaders 0 id
    return $! StatusHeaders status version headers
  where
    getStatusLine = do
        -- Ensure that there is some data coming in. If not, we want to signal
        -- this as a connection problem and not a protocol problem.
        bs <- connectionRead conn
        when (S.null bs) $ throwIO NoResponseDataReceived

        status@(code, _) <- connectionReadLineWith conn bs >>= parseStatus 3
        if code == status100
            then connectionTryReadBlankLine conn >> getStatusLine
            else return status

    parseStatus :: Int -> S.ByteString -> IO (Status, HttpVersion)
    parseStatus i bs | S.null bs && i > 0 = connectionReadLine conn >>= parseStatus (i - 1)
    parseStatus _ bs = do
        let (ver, bs2) = S.breakByte charSpace bs
            (code, bs3) = S.breakByte charSpace $ S.dropWhile (== charSpace) bs2
            msg = S.dropWhile (== charSpace) bs3
        case (,) <$> parseVersion ver <*> readInt code of
            Just (ver', code') -> return (Status code' msg, ver')
            Nothing -> throwIO $ InvalidStatusLine bs

    stripPrefixBS x y
        | x `S.isPrefixOf` y = Just $ S.drop (S.length x) y
        | otherwise = Nothing
    parseVersion bs0 = do
        bs1 <- stripPrefixBS "HTTP/" bs0
        let (num1, S.drop 1 -> num2) = S.breakByte charPeriod bs1
        HttpVersion <$> readInt num1 <*> readInt num2

    readInt bs =
        case S8.readInt bs of
            Just (i, "") -> Just i
            _ -> Nothing

    parseHeaders 100 _ = throwIO OverlongHeaders
    parseHeaders count front = do
        line <- connectionReadLine conn
        if S.null line
            then return $ front []
            else do
                header <- parseHeader line
                parseHeaders (count + 1) $ front . (header:)

    parseHeader :: S.ByteString -> IO Header
    parseHeader bs = do
        let (key, bs2) = S.breakByte charColon bs
        when (S.null bs2) $ throwIO $ InvalidHeader bs
        return (CI.mk $! strip key, strip $! S.drop 1 bs2)

    strip = S.dropWhile (== charSpace) . fst . S.spanEnd (== charSpace)
