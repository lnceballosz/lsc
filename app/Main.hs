{-# LANGUAGE GADTs, DataKinds, TupleSections #-}

module Main where

import Language.SMTLib2
import Language.SMTLib2.Pipe

import LSC
import LSC.Types


main = do
    let gate1 = Gate 4 1
        gate2 = Gate 4 2
        gate3 = Gate 4 3
        wire1 = Wire gate1 gate2 1
        wire2 = Wire gate1 gate3 2
    let netlist = Netlist [gate1, gate2, gate3] [wire1, wire2]
    let tech = Technology (5, 5)
    result <- withBackend pipeZ3 $ stage1 netlist `runLSC` tech
    putStrLn result
