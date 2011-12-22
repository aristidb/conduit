{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
-- | Utilities for constructing and converting 'Source', 'Source' and
-- 'BSource' types. Please see "Data.Conduit.Types.Source" for more information
-- on the base types.
module Data.Conduit.Util.Source
    ( sourceIO
    , transSource
    , sourceState
    , sourceJoin
    ) where

import Control.Monad.Trans.Resource
import Control.Monad.Trans.Class (lift)
import Data.Conduit.Types.Source
import Control.Monad (liftM)
import Data.Monoid

-- | Construct a 'Source' with some stateful functions. This function address
-- all mutable state for you.
sourceState
    :: Resource m
    => state -- ^ Initial state
    -> (state -> ResourceT m (state, SourceResult output)) -- ^ Pull function
    -> Source m output
sourceState state0 pull = Source $ do
    istate <- newRef state0
    return PreparedSource
        { sourcePull = do
            state <- readRef istate
            (state', res) <- pull state
            writeRef istate state'
            return res
        , sourceClose = return ()
        }

-- | Construct a 'Source' based on some IO actions for alloc/release.
sourceIO :: ResourceIO m
          => IO state -- ^ resource and/or state allocation
          -> (state -> IO ()) -- ^ resource and/or state cleanup
          -> (state -> m (SourceResult output)) -- ^ Pull function. Note that this need not explicitly perform any cleanup.
          -> Source m output
sourceIO alloc cleanup pull = Source $ do
    (key, state) <- withIO alloc cleanup
    return PreparedSource
        { sourcePull = do
            res@(SourceResult s _) <- lift $ pull state
            case s of
                StreamClosed -> release key
                _ -> return ()
            return res
        , sourceClose = release key
        }

-- | Transform the monad a 'Source' lives in.
transSource :: (Base m ~ Base n, Monad m)
             => (forall a. m a -> n a)
             -> Source m output
             -> Source n output
transSource f (Source mc) =
    Source (transResourceT f (liftM go mc))
  where
    go c = c
        { sourcePull = transResourceT f (sourcePull c)
        , sourceClose = transResourceT f (sourceClose c)
        }

sourceJoin :: Resource m => Source m (Source m a) -> Source m a
sourceJoin s = Source $ do
  ps <- prepareSource s
  innerSource <- newRef Nothing
  let pull = do inner <- readRef innerSource
                case inner of
                  Just x -> do SourceResult st vs <- sourcePull x
                               case st of
                                 StreamClosed -> writeRef innerSource Nothing
                                 StreamOpen   -> return ()
                               return $ SourceResult StreamOpen vs
                  Nothing -> do SourceResult st xs <- sourcePull ps
                                inner' <- prepareSource $ mconcat xs
                                case st of
                                  StreamOpen   -> do writeRef innerSource (Just inner')
                                                     pull
                                  StreamClosed -> do vs <- eat inner'
                                                     return $ SourceResult StreamClosed vs
      close = do maybe (return ()) sourceClose =<< readRef innerSource
                 sourceClose ps
      eat i = do SourceResult st xs <- sourcePull i
                 case st of
                   StreamClosed -> return xs
                   StreamOpen -> (xs++) `liftM` eat i
  return $ PreparedSource {
      sourcePull = pull
    , sourceClose = close
    }
