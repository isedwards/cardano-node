module Cardano.TraceDispatcher.Resources
  (
    startResourceTracer
  , namesForResources
  , severityResources
  ) where


import           Cardano.Logging
import           Cardano.Logging.Resources
import           Cardano.Prelude hiding (trace)

startResourceTracer ::
     Trace IO ResourceStats
  -> Int
  -> IO ()
startResourceTracer tr delayMilliseconds = do
    as <- async resourceThread
    link as
  where
    resourceThread :: IO ()
    resourceThread = forever $ do
      mbrs <- readResourceStats
      case mbrs of
        Just rs -> traceWith tr rs
        Nothing -> pure ()
      threadDelay (delayMilliseconds * 1000)

namesForResources :: ResourceStats -> [Text]
namesForResources _ = []

severityResources :: ResourceStats -> SeverityS
severityResources _ = Info
