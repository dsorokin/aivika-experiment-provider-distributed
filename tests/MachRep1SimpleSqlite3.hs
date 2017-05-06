
-- It corresponds to model MachRep1 described in document 
-- Introduction to Discrete-Event Simulation and the SimPy Language
-- [http://heather.cs.ucdavis.edu/~matloff/156/PLN/DESimIntro.pdf]. 
-- SimPy is available on [http://simpy.sourceforge.net/].
--   
-- The model description is as follows.
--
-- Two machines, which sometimes break down.
-- Up time is exponentially distributed with mean 1.0, and repair time is
-- exponentially distributed with mean 0.5. There are two repairpersons,
-- so the two machines can be repaired simultaneously if they are down
-- at the same time.
--
-- Output is long-run proportion of up time. Should get value of about
-- 0.66.

import Control.Monad
import Control.Monad.Trans
import Control.Concurrent
import qualified Control.Distributed.Process as DP
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
                spcStopTime = 10000.0,
                spcDT = 1.0,
                spcMethod = RungeKutta4,
                spcGeneratorType = SimpleGenerator }

description =
  "Model MachRep1. Two machines, which sometimes break down. " ++
  "Up time is exponentially distributed with mean 1.0, and repair time is " ++
  "exponentially distributed with mean 0.5. There are two repairpersons, " ++
  "so the two machines can be repaired simultaneously if they are down " ++
  "at the same time. Output is long-run proportion of up time. Should " ++
  "get value of about 0.66."

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
        
model :: Simulation DES (Results DES)
model =
  do totalUpTime <- newRef 0.0
     
     let machine =
           do upTime <-
                liftParameter $
                randomExponential meanUpTime
              holdProcess upTime
              liftEvent $ 
                modifyRef totalUpTime (+ upTime)
              repairTime <-
                liftParameter $
                randomExponential meanRepairTime
              holdProcess repairTime
              machine

     runProcessInStartTime machine
     runProcessInStartTime machine

     let upTimeProp =
           do x <- readRef totalUpTime
              y <- liftDynamics time
              return $ x / (2 * y)

     return $ results
       [resultSource "x" "The proportion of up time" upTimeProp,
        resultSource "t" "Simulation time" time,
        resultSource "n" "Run Index" simulationIndex]

executeMasterModel :: DP.ProcessId -> DIO () -> DP.Process ()
executeMasterModel timeServerId simulation =
  do let ps = defaultDIOParams { dioLoggingPriority = NOTICE }
         m =
           do registerDIO
              simulation
              terminateDIO
     (modelId, modelProcess) <- runDIO m ps timeServerId
     modelProcess

runMasterModel :: DP.ProcessId -> ExperimentProvider -> Int -> DP.Process ()
runMasterModel timeServerId provider runIndex =
  do x <- runExperimentByIndex_ (executeMasterModel timeServerId) experiment generators provider model runIndex
     case x of
       Left e   -> DP.say $ show e
       Right () -> return ()

master = \backend nodes ->
  do liftIO . putStrLn $ "Slaves: " ++ show nodes
     conn <- liftIO $ connectSqlite3 "test.db"
     experimentId <- liftIO newRandomUUID
     agent <- liftIO $ newExperimentAgent conn
     aggregator <- liftIO $ newExperimentAggregator agent (experimentRunCount experiment)
     let provider = ExperimentProvider aggregator (Just experimentId)
     forM_ [1..experimentRunCount experiment] $ \runIndex ->
       do let timeServerParams = defaultTimeServerParams { tsLoggingPriority = DEBUG }
          timeServerId  <- DP.spawnLocal $ timeServer 1 timeServerParams
          runMasterModel timeServerId provider runIndex
     liftIO $ disconnect conn

main :: IO ()
main = do
  backend <- initializeBackend "localhost" "8080" rtable
  startMaster backend (master backend)
    where
      rtable :: DP.RemoteTable
      -- rtable = __remoteTable initRemoteTable
      rtable = initRemoteTable
