
{-# LANGUAGE TypeFamilies, MultiParamTypeClasses #-}

-- |
-- Module     : Simulation.Aivika.Experiment.Distributed.Provider
-- Copyright  : Copyright (c) 2017, David Sorokin <david.sorokin@gmail.com>
-- License    : AllRightsReserved
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 8.0.2
--
-- This module allows using 'DIO' to provide simulation data results.
--

module Simulation.Aivika.Experiment.Distributed.Provider () where

import qualified Control.Monad.Catch as C
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Experiment
import Simulation.Aivika.Experiment.Trans.Provider.Types

import Simulation.Aivika.Distributed

-- | An instance of 'ExperimentMonadProviding'.
instance ExperimentMonadProviding ExperimentProvider DIO where

  -- | This is a synonym for the 'DP.Process' monad.
  type ExperimentMonad ExperimentProvider DIO = DP.Process

-- | An instance of 'ExperimentProviding'.
instance ExperimentProviding ExperimentProvider DIO

-- | An instance of 'MonadException'.
instance MonadException DP.Process where

  catchComp = C.catch
  
  finallyComp = C.finally

  throwComp = C.throwM
