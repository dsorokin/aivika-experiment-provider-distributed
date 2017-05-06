
{--# LANGUAGE TemplateHaskell #--}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}

-- It corresponds to model MachRep2 described in document 
-- Introduction to Discrete-Event Simulation and the SimPy Language
-- [http://heather.cs.ucdavis.edu/~matloff/156/PLN/DESimIntro.pdf]. 
-- SimPy is available on [http://simpy.sourceforge.net/].
--   
-- The model description is as follows.
--   
-- Two machines, but sometimes break down. Up time is exponentially 
-- distributed with mean 1.0, and repair time is exponentially distributed 
-- with mean 0.5. In this example, there is only one repairperson, so 
-- the two machines cannot be repaired simultaneously if they are down 
-- at the same time.
--
-- In addition to finding the long-run proportion of up time as in
-- model MachRep1, let’s also find the long-run proportion of the time 
-- that a given machine does not have immediate access to the repairperson 
-- when the machine breaks down. Output values should be about 0.6 and 0.67. 

import Data.Typeable
import Data.Binary

import GHC.Generics

import Control.Monad
import Control.Monad.Trans
import Control.Exception
import Control.Concurrent
import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet

import Database.HDBC
import Database.HDBC.Sqlite3

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Experiment
import Simulation.Aivika.Experiment.Entity
import Simulation.Aivika.Experiment.Entity.HDBC
import Simulation.Aivika.Experiment.Trans.Provider

import Simulation.Aivika.Distributed
import Simulation.Aivika.Experiment.Distributed.Provider

type DES = DIO

meanUpTime = 1.0
meanRepairTime = 0.5

specs = Specs { spcStartTime = 0.0,
                spcStopTime = 1000.0,
                spcDT = 1.0,
                spcMethod = RungeKutta4,
                spcGeneratorType = SimpleGenerator }

-- | The time shift when replying to the messages.
delta = 1e-6

description =
  "Model MachRep2. Two machines, but sometimes break down. Up time is exponentially " ++
  "distributed with mean 1.0, and repair time is exponentially distributed " ++
  "with mean 0.5. In this example, there is only one repairperson, so " ++
  "the two machines cannot be repaired simultaneously if they are down " ++
  "at the same time. In addition to finding the long-run proportion of up time, " ++
  "let’s also find the long-run proportion of the time " ++
  "that a given machine does not have immediate access to the repairperson " ++
  "when the machine breaks down. Output values should be about 0.6 and 0.67."

experiment :: Experiment DES
experiment =
  defaultExperiment {
    experimentSpecs = specs,
    experimentRunCount = 3,
    experimentDescription = description }

x = resultByName "x"
t = resultByName "t"

generators :: [ExperimentGenerator ExperimentProvider DES]
generators =
  [outputView $ defaultLastValueView {
     lastValueKey = "last value 1" },
   outputView $ defaultTimeSeriesView {
     timeSeriesKey = "time series 1" },
   outputView $ defaultFinalDeviationView {
     finalDeviationKey = "final deviation 1" },
   outputView $ defaultDeviationView {
     deviationKey = "deviation 1" },
   outputView $ defaultLastValueListView {
     lastValueListKey = "last value list 1" },
   outputView $ defaultMultipleLastValueListView {
     multipleLastValueListKey = "multiple last value list 1" },
   outputView $ defaultValueListView {
     valueListKey = "value list 1" },
   outputView $ defaultMultipleValueListView {
     multipleValueListKey = "multiple value list 1" },
   outputView $ defaultFinalSamplingStatsView {
     finalSamplingStatsKey = "final sample-based statistics 1" },
   outputView $ defaultSamplingStatsView {
     samplingStatsKey = "sample-based statistics 1" }]

data TotalUpTimeChange = TotalUpTimeChange (DP.ProcessId, Double) deriving (Eq, Ord, Show, Typeable, Generic)
data TotalUpTimeChangeResp = TotalUpTimeChangeResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

data NRepChange = NRepChange (DP.ProcessId, Int) deriving (Eq, Ord, Show, Typeable, Generic)
data NRepChangeResp = NRepChangeResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

data NImmedRepChange = NImmedRepChange (DP.ProcessId, Int) deriving (Eq, Ord, Show, Typeable, Generic)
data NImmedRepChangeResp = NImmedRepChangeResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

data RepairPersonCount = RepairPersonCount DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)
data RepairPersonCountResp = RepairPersonCountResp (DP.ProcessId, Int) deriving (Eq, Ord, Show, Typeable, Generic)

data RequestRepairPerson = RequestRepairPerson DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)
data RequestRepairPersonResp = RequestRepairPersonResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

data ReleaseRepairPerson = ReleaseRepairPerson DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)
data ReleaseRepairPersonResp = ReleaseRepairPersonResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary TotalUpTimeChange
instance Binary TotalUpTimeChangeResp

instance Binary NRepChange
instance Binary NRepChangeResp

instance Binary NImmedRepChange
instance Binary NImmedRepChangeResp

instance Binary RepairPersonCount
instance Binary RepairPersonCountResp

instance Binary RequestRepairPerson
instance Binary RequestRepairPersonResp

instance Binary ReleaseRepairPerson
instance Binary ReleaseRepairPersonResp

-- | A sub-model.
slaveModel :: DP.ProcessId -> Simulation DIO ()
slaveModel masterId =
  do inboxId <- liftComp messageInboxId

     let machine =
           do t <- liftDynamics time
              upTime <-
                liftParameter $ randomExponential meanUpTime
              enqueueMessage masterId (t + delta + upTime) (TotalUpTimeChange (inboxId, upTime))
              enqueueMessage masterId (t + delta + upTime) (NRepChange (inboxId, 1))
              enqueueMessage masterId (t + delta + upTime) (RepairPersonCount inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(RepairPersonCountResp (senderId, n)) ->
       do t <- liftDynamics time
          when (n == 1) $
            enqueueMessage masterId (t + delta) (NImmedRepChange (inboxId, 1))
          enqueueMessage masterId (t + delta) (RequestRepairPerson inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(RequestRepairPersonResp senderId) ->
       do t <- liftDynamics time
          repairTime <-
            liftParameter $ randomExponential meanRepairTime
          enqueueMessage masterId (t + delta + repairTime) (ReleaseRepairPerson inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(ReleaseRepairPersonResp senderId) ->
       machine
  
     runEventInStartTime machine

     runEventInStartTime $
       enqueueEventIOWithStopTime $
       liftIO $
       putStrLn "The sub-model finished"

     runEventInStopTime $
       return ()

-- | The main model.       
masterModel :: Int -> Simulation DIO (Results DIO)
masterModel count =
  do totalUpTime <- newRef 0.0
     nRep <- newRef 0
     nImmedRep <- newRef 0

     let maxRepairPersonCount = 1
     repairPerson <- newFCFSResource maxRepairPersonCount

     inboxId <- liftComp messageInboxId

     runEventInStartTime $
       handleSignal messageReceived $ \(TotalUpTimeChange (senderId, x)) ->
       do modifyRef totalUpTime (+ x)
          t <- liftDynamics time
          enqueueMessage senderId (t + delta) (TotalUpTimeChangeResp inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(NRepChange (senderId, x)) ->
       do modifyRef nRep (+ x)
          t <- liftDynamics time
          enqueueMessage senderId (t + delta) (NRepChangeResp inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(NImmedRepChange (senderId, x)) ->
       do modifyRef nImmedRep (+ x)
          t <- liftDynamics time
          enqueueMessage senderId (t + delta) (NImmedRepChangeResp inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(RepairPersonCount senderId) ->
       do n <- resourceCount repairPerson
          t <- liftDynamics time
          enqueueMessage senderId (t + delta) (RepairPersonCountResp (inboxId, n))

     runEventInStartTime $
       handleSignal messageReceived $ \(RequestRepairPerson senderId) ->
       runProcess $
       do requestResource repairPerson
          t <- liftDynamics time
          liftEvent $
            enqueueMessage senderId (t + delta) (RequestRepairPersonResp inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(ReleaseRepairPerson senderId) ->
       do t <- liftDynamics time
          releaseResourceWithinEvent repairPerson
          enqueueMessage senderId (t + delta) (ReleaseRepairPersonResp inboxId)
          
     let upTimeProp =
           do x <- readRef totalUpTime
              y <- liftDynamics time
              return $ x / (fromIntegral count * y)

         immedProp :: Event DES Double
         immedProp =
           do n <- readRef nRep
              nImmed <- readRef nImmedRep
              return $
                fromIntegral nImmed /
                fromIntegral n

     return $ results
       [resultSource "x" "The proportion of up time" upTimeProp,
        resultSource "y" "The proportion of immediate access" immedProp,
        resultSource "t" "Simulation time" time,
        resultSource "n" "Run Index" simulationIndex]

runSlaveModel :: (DP.ProcessId, DP.ProcessId) -> DP.Process (DP.ProcessId, DP.Process ())
runSlaveModel (timeServerId, masterId) =
  runDIO m ps timeServerId
  where
    ps = defaultDIOParams { dioLoggingPriority = WARNING }
    m  = do registerDIO
            runSimulation (slaveModel masterId) specs
            unregisterDIO

executeMasterModel :: DP.ProcessId -> DIO () -> DP.Process (DP.ProcessId, DP.Process ())
executeMasterModel timeServerId simulation =
  do let ps = defaultDIOParams { dioLoggingPriority = WARNING }
         m =
           do registerDIO
              simulation
              terminateDIO
     runDIO m ps timeServerId

type ProcessTry a = DP.Process (Either SomeException a)

runMasterModel :: DP.ProcessId -> Int -> ExperimentProvider -> Int -> DP.Process (DP.ProcessId, DP.Process ())
runMasterModel timeServerId n provider runIndex =
  do x <- runExperimentContByIndex (executeMasterModel timeServerId) experiment generators provider (masterModel n) runIndex
     case x of
       Left e -> throw e
       Right (pid, cont) ->
         let m = do y <- cont
                    case y of
                      Left e -> throw e
                      Right () -> return ()
         in return (pid, m)

master = \backend nodes ->
  do liftIO . putStrLn $ "Slaves: " ++ show nodes
     conn <- liftIO $ connectSqlite3 "test.db"
     experimentId <- liftIO newRandomUUID
     agent <- liftIO $ newExperimentAgent conn
     aggregator <- liftIO $ newExperimentAggregator agent (experimentRunCount experiment)
     let provider = ExperimentProvider aggregator (Just experimentId)
     forM_ [1..experimentRunCount experiment] $ \runIndex ->
       do let n = 2
              timeServerParams = defaultTimeServerParams { tsLoggingPriority = DEBUG }
          timeServerId <- DP.spawnLocal $ timeServer 3 timeServerParams
          (masterId, masterProcess) <- runMasterModel timeServerId n provider runIndex
          forM_ [1..n] $ \i ->
            do (slaveId, slaveProcess) <- runSlaveModel (timeServerId, masterId)
               DP.spawnLocal slaveProcess
          masterProcess
     liftIO $ disconnect conn
  
main :: IO ()
main = do
  backend <- initializeBackend "localhost" "8080" rtable
  startMaster backend (master backend)
    where
      rtable :: DP.RemoteTable
      -- rtable = __remoteTable initRemoteTable
      rtable = initRemoteTable
