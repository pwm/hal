{-# LANGUAGE FlexibleContexts #-}

{-|
Module      : AWS.Lambda.ApiGatewayRuntime
Description : Runtime methods useful when constructing Haskell handlers for the AWS Lambda Custom Runtime.
Copyright   : (c) Nike, Inc., 2018
License     : BSD3
Maintainer  : nathan.fairhurst@nike.com, fernando.freire@nike.com
Stability   : stable
-}

module AWS.Lambda.ApiGatewayRuntime (
  pureRuntime,
  pureRuntimeWithContext,
  fallibleRuntime,
  fallibleRuntimeWithContext,
  ioRuntime,
  ioRuntimeWithContext,
  readerTRuntime,
  mRuntimeWithContext
) where

import           AWS.Lambda.Context                        (HasLambdaContext (..),
                                                            LambdaContext (..))
import           AWS.Lambda.Events.ApiGatewayProxyRequest  (ApiGatewayProxyRequest (..))
import           AWS.Lambda.Events.ApiGatewayProxyResponse (ApiGatewayProxyResponse (..))
import           AWS.Lambda.Events.NeedsARealName          (NeedsARealName,
                                                            expectJSON,
                                                            needsARealName,
                                                            needsARealNameJSON)
import qualified AWS.Lambda.Runtime                        as Runtime
import           Control.Monad.Catch                       (MonadCatch)
import           Control.Monad.IO.Class                    (MonadIO, liftIO)
import           Control.Monad.Reader                      (MonadReader,
                                                            ReaderT, ask,
                                                            runReaderT)
import           Data.Aeson                                (FromJSON)
import           Data.ByteString.Lazy                      (ByteString)
import           Data.Profunctor                           (lmap)
import           System.Envy                               (defConfig)

with400 :: Monad m => ApiGatewayProxyResponse -> (a -> m ApiGatewayProxyResponse) -> (Maybe a -> m ApiGatewayProxyResponse)
with400 res400 fn e =
  case e of
    Just json -> fn json
    Nothing   -> return res400

withApiGateway :: (NeedsARealName (Bool, ByteString) -> a) -> (ApiGatewayProxyRequest -> a)
withApiGateway = lmap needsARealName

withJSONBody :: FromJSON json => (Maybe (NeedsARealName json) -> a) -> (NeedsARealName (Bool, ByteString) -> a)
withJSONBody = lmap expectJSON

mRuntimeWithContext :: (HasLambdaContext r, MonadCatch m, MonadReader r m, MonadIO m, FromJSON json) =>
  ApiGatewayProxyResponse -> (NeedsARealName json -> m ApiGatewayProxyResponse) -> m ()
mRuntimeWithContext res400 =
  Runtime.mRuntimeWithContext . withApiGateway . withJSONBody . with400 res400

-- | Helper for using arbitrary monads with only the LambdaContext in its Reader
runReaderTLambdaContext :: ReaderT LambdaContext m a -> m a
runReaderTLambdaContext = flip runReaderT defConfig

readerTRuntime :: FromJSON json =>
  ApiGatewayProxyResponse -> (NeedsARealName json -> ReaderT LambdaContext IO ApiGatewayProxyResponse) -> IO ()
readerTRuntime res400 =
  runReaderTLambdaContext . mRuntimeWithContext res400

withIOInterface :: (MonadReader c m, MonadIO m) => (c -> b -> IO (Either String a)) -> (b -> m a)
withIOInterface fn = \event -> do
   config <- ask
   result <- liftIO $ fn config event
   case result of
     Left e  -> error e
     Right x -> return x


ioRuntimeWithContext :: FromJSON json =>
  ApiGatewayProxyResponse -> (LambdaContext -> NeedsARealName json -> IO (Either String ApiGatewayProxyResponse)) -> IO ()
ioRuntimeWithContext res400 =
  runReaderTLambdaContext . Runtime.mRuntimeWithContext . withApiGateway . withJSONBody . with400 res400 . withIOInterface

ioRuntime :: FromJSON json =>
  ApiGatewayProxyResponse -> (NeedsARealName json -> IO (Either String ApiGatewayProxyResponse)) -> IO ()
ioRuntime res404 fn = ioRuntimeWithContext res404 wrapped
    where wrapped _ = fn


fallibleRuntimeWithContext :: FromJSON json =>
  ApiGatewayProxyResponse -> (LambdaContext -> NeedsARealName json -> Either String ApiGatewayProxyResponse) -> IO ()
fallibleRuntimeWithContext res404 fn = ioRuntimeWithContext res404 wrapped
  where wrapped c e = return $ fn c e


fallibleRuntime :: FromJSON json =>
  ApiGatewayProxyResponse -> (NeedsARealName json -> Either String ApiGatewayProxyResponse) -> IO ()
fallibleRuntime res404 fn = fallibleRuntimeWithContext res404 wrapped
  where
    wrapped _ = fn


pureRuntimeWithContext :: FromJSON json =>
  ApiGatewayProxyResponse -> (LambdaContext -> NeedsARealName json -> ApiGatewayProxyResponse) -> IO ()
pureRuntimeWithContext res404 fn = fallibleRuntimeWithContext res404 wrapped
  where wrapped c e = Right $ fn c e


pureRuntime :: FromJSON json => ApiGatewayProxyResponse -> (NeedsARealName json -> ApiGatewayProxyResponse) -> IO ()
pureRuntime res404 fn = fallibleRuntime res404 (Right . fn)