{-|
Module      : Control.Error.Context.Simple
Description : API for enriching errors with contexts
Copyright   : (c) Moritz Clasmeier 2018
License     : BSD3
Maintainer  : mtesseract@silverratio.net
Stability   : experimental
Portability : POSIX
-}

{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE UndecidableInstances       #-}

module Control.Error.Context.Simple
  ( ErrorContextT(..)
  , runErrorContextT
  )
where

import           Control.Error.Context.Types
import           Data.Typeable
import           Data.Aeson

import           Control.Error.Context.Exception

import           Control.Monad.Catch            ( Handler(..)
                                                , MonadCatch(..)
                                                , SomeException(..)
                                                , MonadThrow
                                                , MonadMask
                                                , throwM
                                                , catches
                                                )
import           Control.Monad.IO.Unlift
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Trans.Resource
import           Control.Monad.Writer
import qualified Data.Aeson.KeyMap              as KeyMap
import qualified Data.Aeson.Key                 as Key
import           Data.Text                      ( Text )

-- | Data type implementing 'MonadErrorContext'.
newtype ErrorContextT m a =
  ErrorContextT { _runErrorContextT :: ReaderT ErrorContext m a
                } deriving ( Functor
                           , Applicative
                           , Monad
                           , MonadTrans
                           , MonadState s
                           , MonadWriter w
                           , MonadMask )

runErrorContextT :: ErrorContextT m a -> m a
runErrorContextT = flip runReaderT mempty . _runErrorContextT

instance (MonadCatch m, MonadIO m) => MonadIO (ErrorContextT m) where
  liftIO m = do
    ctx <- errorContextCollect
    lift $ errorContextualizeIO ctx m

    where errorContextualizeIO ctx io = liftIO $
            catch io $ \ (SomeException exn) -> throwM (ErrorWithContext ctx exn)

instance (MonadCatch m) => MonadThrow (ErrorContextT m) where
  throwM = throwWithContext

errorNamespacePush :: Text -> ErrorContext -> ErrorContext
errorNamespacePush label ctx =
  let currentNamespace = errorContextNamespace ctx
  in  ctx { errorContextNamespace = currentNamespace ++ [label] }

errorContextAdd :: Text -> Value -> ErrorContext -> ErrorContext
errorContextAdd label val ctx =
  let currentKVs = errorContextKVs ctx
  in  ctx { errorContextKVs = KeyMap.insert (Key.fromText label) val currentKVs }

instance (MonadCatch m) => MonadErrorContext (ErrorContextT m) where
  errorContextCollect = ErrorContextT ask
  withErrorNamespace layer (ErrorContextT m) =
    ErrorContextT (local (errorNamespacePush layer) m)
  withErrorContext label val (ErrorContextT m) =
    ErrorContextT (local (errorContextAdd label (toJSON val)) m)

instance (MonadCatch m) => MonadCatch (ErrorContextT m) where
  catch (ErrorContextT m) f = ErrorContextT $
    catches m
    [ Handler $ \(ErrorWithContext _ctx exn :: ErrorWithContext e) -> _runErrorContextT (f exn)
    , Handler $ \(exn :: e) -> _runErrorContextT (f exn)
    ]

instance (MonadCatch m) => MonadCatchRaw (ErrorContextT m) where
  catchRaw (ErrorContextT m) f = ErrorContextT $
    catch m (_runErrorContextT . f)

instance (MonadCatch m, MonadResource m) => MonadResource (ErrorContextT m) where
  liftResourceT = liftResourceT

instance MonadReader r m => MonadReader r (ErrorContextT m) where
  ask = ErrorContextT (lift ask)
  local f (ErrorContextT (ReaderT m)) =
    ErrorContextT (ReaderT (\ errCtx -> local f (m errCtx)))

instance (MonadUnliftIO m, MonadCatch m) => MonadUnliftIO (ErrorContextT m) where

  withRunInIO inner = 
    ErrorContextT $ 
    withRunInIO $ \run ->
    inner (run . _runErrorContextT)
{-
  askUnliftIO = do
    env <- ErrorContextT ask
    unlifter <- lift askUnliftIO
    pure $ UnliftIO (\ (ErrorContextT ec) -> unliftIO unlifter (runReaderT ec env))

  withRunInIO :: ((forall a. m a -> IO a) -> IO b) -> m b
-- for ReaderT
  withRunInIO inner =
    ReaderT $ \r ->
    withRunInIO $ \run ->
    inner (run . flip runReaderT r)


askUnliftIO :: MonadUnliftIO m => m (UnliftIO m)
askUnliftIO = withRunInIO (\run -> return (UnliftIO run))
{-# INLINE askUnliftIO #-}
-- Would be better, but GHC hates us
-- askUnliftIO :: m (forall a. m a -> IO a)
-- -}
