{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PackageImports      #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Logging.Forwarding
  (
    initForwarding
  ) where

import           Codec.CBOR.Term (Term)
import           Control.Concurrent.Async (async, race_, wait)
import           Control.Monad (void)
import           Control.Monad.IO.Class

import           "contra-tracer" Control.Tracer (contramap, stdoutTracer)
import qualified Data.ByteString.Lazy as LBS
import           Data.Void (Void)
import           Data.Word (Word16)

import           Ouroboros.Network.Driver.Limits (ProtocolTimeLimits)
import           Ouroboros.Network.ErrorPolicy (nullErrorPolicies)
import           Ouroboros.Network.IOManager (IOManager)
import           Ouroboros.Network.Mux (MiniProtocol (..),
                     MiniProtocolLimits (..), MiniProtocolNum (..),
                     MuxMode (..), OuroborosApplication (..),
                     RunMiniProtocol (..), miniProtocolLimits, miniProtocolNum,
                     miniProtocolRun)
import           Ouroboros.Network.Protocol.Handshake.Codec
                     (cborTermVersionDataCodec, noTimeLimitsHandshake)
import           Ouroboros.Network.Protocol.Handshake.Type (Handshake)
import           Ouroboros.Network.Protocol.Handshake.Unversioned
                     (UnversionedProtocol (..), UnversionedProtocolData (..),
                     unversionedHandshakeCodec, unversionedProtocolDataCodec)
import           Ouroboros.Network.Protocol.Handshake.Version
                     (acceptableVersion, simpleSingletonVersions)
import           Ouroboros.Network.Snocket (Snocket, localAddressFromPath,
                     localSnocket)
import           Ouroboros.Network.Socket (AcceptedConnectionsLimit (..),
                     SomeResponderApplication (..), cleanNetworkMutableState,
                     connectToNode, newNetworkMutableState, nullNetworkConnectTracers,
                     nullNetworkServerTracers, withServerNode)

import qualified DataPoint.Forward.Configuration as DPF
import           DataPoint.Forward.Network.Forwarder
import           DataPoint.Forward.Utils (DataPointStore, initDataPointStore)
import qualified System.Metrics as EKG
import qualified System.Metrics.Configuration as EKGF
import           System.Metrics.Network.Forwarder
import qualified Trace.Forward.Configuration as TF
import           Trace.Forward.Network.Forwarder
import           Trace.Forward.Utils

import           Cardano.Logging.Types

initForwarding :: forall m. (MonadIO m)
  => IOManager
  -> TraceConfig
  -> EKG.Store
  -> m (ForwardSink TraceObject, DataPointStore)
initForwarding iomgr config ekgStore = liftIO $ do
  forwardSink <- initForwardSink tfConfig
  dpStore <- initDataPointStore
  launchForwarders
    iomgr
    config
    ekgConfig
    tfConfig
    dpfConfig
    ekgStore
    forwardSink
    dpStore
  pure (forwardSink, dpStore)
 where
  LocalSocket p = tofAddress $ tcForwarder config

  ekgConfig :: EKGF.ForwarderConfiguration
  ekgConfig =
    EKGF.ForwarderConfiguration
      { EKGF.forwarderTracer    = contramap show stdoutTracer
      , EKGF.acceptorEndpoint   = EKGF.LocalPipe p
      , EKGF.reConnectFrequency = 1.0
      , EKGF.actionOnRequest    = const $ pure ()
      }

  tfConfig :: TF.ForwarderConfiguration TraceObject
  tfConfig =
    TF.ForwarderConfiguration
      { TF.forwarderTracer       = contramap show stdoutTracer
      , TF.acceptorEndpoint      = TF.LocalPipe p
      , TF.disconnectedQueueSize = 200000
      , TF.connectedQueueSize    = 2000
      }

  dpfConfig :: DPF.ForwarderConfiguration
  dpfConfig =
    DPF.ForwarderConfiguration
      { DPF.forwarderTracer  = contramap show stdoutTracer
      , DPF.acceptorEndpoint = DPF.LocalPipe p
      }

launchForwarders
  :: IOManager
  -> TraceConfig
  -> EKGF.ForwarderConfiguration
  -> TF.ForwarderConfiguration TraceObject
  -> DPF.ForwarderConfiguration
  -> EKG.Store
  -> ForwardSink TraceObject
  -> DataPointStore
  -> IO ()
launchForwarders iomgr TraceConfig{tcForwarder} ekgConfig tfConfig dpfConfig ekgStore sink dpStore =
  void . async $
    runActionInLoop
      (launchForwardersViaLocalSocket
         iomgr
         tcForwarder
         ekgConfig
         tfConfig
         dpfConfig
         sink
         ekgStore
         dpStore)
      (TF.LocalPipe p)
      1
 where
  LocalSocket p = tofAddress tcForwarder

launchForwardersViaLocalSocket
  :: IOManager
  -> TraceOptionForwarder
  -> EKGF.ForwarderConfiguration
  -> TF.ForwarderConfiguration TraceObject
  -> DPF.ForwarderConfiguration
  -> ForwardSink TraceObject
  -> EKG.Store
  -> DataPointStore
  -> IO ()
launchForwardersViaLocalSocket iomgr
  TraceOptionForwarder {tofAddress=(LocalSocket p), tofMode=Initiator}
  ekgConfig tfConfig dpfConfig sink ekgStore dpStore =
    doConnectToAcceptor (localSnocket iomgr) (localAddressFromPath p)
      noTimeLimitsHandshake ekgConfig tfConfig dpfConfig sink ekgStore dpStore
launchForwardersViaLocalSocket iomgr
  TraceOptionForwarder {tofAddress=(LocalSocket p), tofMode=Responder}
  ekgConfig tfConfig dpfConfig sink ekgStore dpStore =
    doListenToAcceptor (localSnocket iomgr) (localAddressFromPath p)
      noTimeLimitsHandshake ekgConfig tfConfig dpfConfig sink ekgStore dpStore

doConnectToAcceptor
  :: Snocket IO fd addr
  -> addr
  -> ProtocolTimeLimits (Handshake UnversionedProtocol Term)
  -> EKGF.ForwarderConfiguration
  -> TF.ForwarderConfiguration TraceObject
  -> DPF.ForwarderConfiguration
  -> ForwardSink TraceObject
  -> EKG.Store
  -> DataPointStore
  -> IO ()
doConnectToAcceptor snocket address timeLimits ekgConfig tfConfig dpfConfig sink ekgStore dpStore = do
  connectToNode
    snocket
    unversionedHandshakeCodec
    timeLimits
    (cborTermVersionDataCodec unversionedProtocolDataCodec)
    nullNetworkConnectTracers
    acceptableVersion
    (simpleSingletonVersions
       UnversionedProtocol
       UnversionedProtocolData
         (forwarderApp [ (forwardEKGMetrics   ekgConfig ekgStore, 1)
                       , (forwardTraceObjects tfConfig  sink,     2)
                       , (forwardDataPoints   dpfConfig dpStore,  3)
                       ]
         )
    )
    Nothing
    address
 where
  forwarderApp
    :: [(RunMiniProtocol 'InitiatorMode LBS.ByteString IO () Void, Word16)]
    -> OuroborosApplication 'InitiatorMode addr LBS.ByteString IO () Void
  forwarderApp protocols =
    OuroborosApplication $ \_connectionId _shouldStopSTM ->
      [ MiniProtocol
         { miniProtocolNum    = MiniProtocolNum num
         , miniProtocolLimits = MiniProtocolLimits { maximumIngressQueue = maxBound }
         , miniProtocolRun    = prot
         }
      | (prot, num) <- protocols
      ]

doListenToAcceptor
  :: Ord addr
  => Snocket IO fd addr
  -> addr
  -> ProtocolTimeLimits (Handshake UnversionedProtocol Term)
  -> EKGF.ForwarderConfiguration
  -> TF.ForwarderConfiguration TraceObject
  -> DPF.ForwarderConfiguration
  -> ForwardSink TraceObject
  -> EKG.Store
  -> DataPointStore
  -> IO ()
doListenToAcceptor snocket address timeLimits ekgConfig tfConfig dpfConfig sink ekgStore dpStore = do
  networkState <- newNetworkMutableState
  race_ (cleanNetworkMutableState networkState)
        $ withServerNode
            snocket
            nullNetworkServerTracers
            networkState
            (AcceptedConnectionsLimit maxBound maxBound 0)
            address
            unversionedHandshakeCodec
            timeLimits
            (cborTermVersionDataCodec unversionedProtocolDataCodec)
            acceptableVersion
            (simpleSingletonVersions
              UnversionedProtocol
              UnversionedProtocolData
              (SomeResponderApplication $
                forwarderApp [ (forwardEKGMetricsResp   ekgConfig ekgStore, 1)
                             , (forwardTraceObjectsResp tfConfig  sink,     2)
                             , (forwardDataPointsResp   dpfConfig dpStore,  3)
                             ]
              )
            )
            nullErrorPolicies
            $ \_ serverAsync ->
              wait serverAsync -- Block until async exception.
 where
  forwarderApp
    :: [(RunMiniProtocol 'ResponderMode LBS.ByteString IO Void (), Word16)]
    -> OuroborosApplication 'ResponderMode addr LBS.ByteString IO Void ()
  forwarderApp protocols =
    OuroborosApplication $ \_connectionId _shouldStopSTM ->
      [ MiniProtocol
         { miniProtocolNum    = MiniProtocolNum num
         , miniProtocolLimits = MiniProtocolLimits { maximumIngressQueue = maxBound }
         , miniProtocolRun    = prot
         }
      | (prot, num) <- protocols
      ]
