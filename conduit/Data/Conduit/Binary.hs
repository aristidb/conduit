{-# LANGUAGE FlexibleContexts #-}
-- | Functions for interacting with bytes.
module Data.Conduit.Binary
    ( sourceFile
    , sourceFileRange
    , sinkFile
    , conduitFile
    , isolate
    ) where

import qualified Data.ByteString as S
import Data.Conduit
import Control.Exception (assert)
import Control.Monad.IO.Class (liftIO)
import qualified System.IO as IO
import Control.Monad.Trans.Resource (withIO, release, newRef, readRef, writeRef)

-- | Stream the contents of a file as binary data.
sourceFile :: ResourceIO m
           => FilePath
           -> Source m S.ByteString
sourceFile fp = sourceIO
    (IO.openFile fp IO.ReadMode)
    IO.hClose
    (\handle -> do
        bs <- liftIO $ S.hGetSome handle 4096
        if S.null bs
            then return Closed
            else return $ Open bs)

-- | Stream the contents of a file as binary data, starting from a certain
-- offset and only consuming up to a certain number of bytes.
sourceFileRange :: ResourceIO m
                => FilePath
                -> Maybe Integer -- ^ Offset
                -> Maybe Integer -- ^ Maximum count
                -> Source m S.ByteString
sourceFileRange fp offset count = Source $ do
    (key, handle) <- withIO (IO.openFile fp IO.ReadMode) IO.hClose
    case offset of
        Nothing -> return ()
        Just off -> liftIO $ IO.hSeek handle IO.AbsoluteSeek off
    pull <-
        case count of
            Nothing -> return $ pullUnlimited handle key
            Just c -> do
                ic <- newRef c
                return $ pullLimited ic handle key
    return PreparedSource
        { sourcePull = pull
        , sourceClose = release key
        }
  where
    pullUnlimited handle key = do
        bs <- liftIO $ S.hGetSome handle 4096
        if S.null bs
            then do
                release key
                return Closed
            else return $ Open bs
    pullLimited ic handle key = do
        c <- fmap fromInteger $ readRef ic
        bs <- liftIO $ S.hGetSome handle (min c 4096)
        let c' = c - S.length bs
        assert (c' >= 0) $
            if S.null bs
                then do
                    release key
                    return Closed
                else do
                    writeRef ic $ toInteger c'
                    return $ Open bs

-- | Stream all incoming data to the given file.
sinkFile :: ResourceIO m
         => FilePath
         -> Sink S.ByteString m ()
sinkFile fp = sinkIO
    (IO.openFile fp IO.WriteMode)
    IO.hClose
    (\handle bs -> liftIO (S.hPut handle bs) >> return Processing)
    (const $ return ())

-- | Stream the contents of the input to a file, and also send it along the
-- pipeline. Similar in concept to the Unix command @tee@.
conduitFile :: ResourceIO m
            => FilePath
            -> Conduit S.ByteString m S.ByteString
conduitFile fp = conduitIO
    (IO.openFile fp IO.WriteMode)
    IO.hClose
    (\handle bs -> do
        liftIO $ S.hPut handle bs
        return $ Producing [bs])
    (const $ return [])

-- | Ensure that only up to the given number of bytes are consume by the inner
-- sink. Note that this does /not/ ensure that all of those bytes are in fact
-- consumed.
isolate :: Resource m
        => Int
        -> Conduit S.ByteString m S.ByteString
isolate count0 = conduitState
    count0
    push
    close
  where
    push 0 bs = return (0, Finished (Just bs) [])
    push count bs = do
        let (a, b) = S.splitAt count bs
        let count' = count - S.length a
        return (count',
            if count' == 0
                then Finished (if S.null b then Nothing else Just b) (if S.null a then [] else [a])
                else assert (S.null b) $ Producing [a])
    close _ = return []
