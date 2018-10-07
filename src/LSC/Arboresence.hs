{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# LANGUAGE GADTs, DataKinds, TupleSections, FlexibleContexts #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LSC.Arboresence where

import Control.Monad.Trans
import Data.Default
import Data.Foldable
import qualified Data.Map as Map
import Data.SBV
import Data.SBV.Control
import Data.Text (unpack)
import System.IO

import LSC.Types


pnr :: NetGraph -> LSC Stage1
pnr (NetGraph name pins _ gates wires) = do

  debug
    [ "start pnr @ module", unpack name
    , "-", show $ length gates, "gates"
    , "-", show $ length wires, "nets"
    ]

  liftSMT $ do
    setOption $ ProduceUnsatCores True

  nodes <- Map.fromList <$> sequence (freeGatePolygon <$> toList gates)

  boundedSpace nodes
  collision nodes

  steiner <- arboresence pins nodes wires

  rectilinear steiner

  result <- computeStage1 nodes steiner

  debug ["stop  pnr @ module", unpack name]

  pure result


arboresence pins@(inputs, _, _) nodes wires = concat <$>
  sequence
    [ do

      source <- freePoint

      if netIdent wire `elem` inputs
      then do
        liftSMT $ constrain $ bAnd [ fst source .< x | (x, _) : _ <- toList nodes ]
      else do
        liftSMT $ constrain $ bAnd
          [ source .== (fst bottomLeft + literal px, snd bottomLeft + literal py)
          | (gate, cs) <- Map.assocs $ contacts wire
          , (_, pin) <- take 1 cs
          , pinDir pin == Out
          , (px, py, _, _) <- take 1 $ portRects $ pinPort pin
          , bottomLeft <- maybe [] (take 1) $ Map.lookup gate nodes
          ]

      tree <- arbor pins nodes wire source

      liftSMT $ constrain $ allEqual $ manhattan . snd <$> tree

      pure tree

    | wire <- toList wires
    ]


arbor pins@(_, outputs, _) nodes net source = do
  sequence
    [ do

      (_, edge) <- freeWirePolygon net

      target <- case Map.lookup gate nodes of
        Just (bottomLeft : _) -> do
          pure (fst bottomLeft + literal px, snd bottomLeft + literal py)
        _ -> do
          target <- freePoint
          liftSMT $ constrain $ bAnd [ fst target .> x | _ : _ : (x, _) : _ <- toList nodes ]
          pure target

      liftSMT $ do
        constrain $ head edge .== source
        constrain $ last edge .== target

      pure ((net, idn), edge)

    | (gate, cs) <- Map.assocs (contacts net)
                 ++ [ (def, [(netIdent net, def)]) | netIdent net `elem` outputs ]
    , (idn, pin) <- take 1 cs
    , pinDir pin == In
    , (px, py, _, _) <- take 1 $ portRects $ pinPort pin
    ]


manhattan :: [(SInteger, SInteger)] -> SInteger
manhattan ((x1, y1) : (x2, y2) : xs)
  = abs (x1 - x2)
  + abs (y1 - y2)
  + manhattan ((x2, y2) : xs)
manhattan _ = 0


boundedSpace nodes = do
  (w, h) <- padDimensions <$> ask
  sequence_
    [ liftSMT $ do
        constrain $ x .> literal 0 &&& y .> literal 0
        constrain $ x .< literal w &&& y .< literal h
    | rect <- Map.elems nodes
    , (x, y) <- take 1 rect
    ]


rectilinear steiner = sequence_ [ uniform edge *> rectangular edge | (_, edge) <- steiner ]

rectangular ((x1, y1) : (x2, y2) : xs) = do
  liftSMT $ constrain $ x1 .== x2 ||| y1 .== y2
  rectangular ((x2, y2) : xs)
rectangular _ = pure ()


segments (x : y : xs) = (x, y) : segments (y : xs)
segments _ = []


uniform ((x1, y1) : (x2, y2) : (x3, y3) : xs) = do
  liftSMT $ do
    constrain $ (x1, y1) .== (x2, y2)
      ||| (x3 - x2 .> 0) .== (x1 - x2 .> 0)
      &&& (y3 - y2 .> 0) .== (y1 - y2 .> 0)
  uniform ((x2, y2) : (x3, y3) : xs)
uniform _ = pure ()


collision nodes = do
  sequence_
    [ do

      liftSMT $ do
        constrain $ fst topLeft1 .> fst bottomRight2 ||| fst topLeft2 .> fst bottomRight1
        constrain $ snd topLeft1 .< snd bottomRight2 ||| snd topLeft2 .< snd bottomRight1

    | (i, path1) <- [ 1 .. ] `zip` Map.elems nodes
    ,     path2  <- i `drop` Map.elems nodes
    , let _ : topLeft1 : _ : bottomRight1 : _ = path1
    , let _ : topLeft2 : _ : bottomRight2 : _ = path2
    ]


freeGatePolygon gate = do

  (width, height) <- lookupDimensions gate <$> ask

  path <- freePolygon 4

  let bottomLeft : topLeft : topRight : bottomRight : _ = path

  liftSMT $ constrain
    $   snd topLeft - snd bottomLeft .== literal height
    &&& fst topLeft .== fst bottomLeft

    &&& snd topRight - snd bottomRight .== literal height
    &&& fst topRight .== fst bottomRight

    &&& fst topRight - fst topLeft .== literal width
    &&& snd topRight .== snd topLeft

    &&& fst bottomRight - fst bottomLeft .== literal width
    &&& snd bottomRight .== snd bottomLeft

  pure (gate, path)


freeWirePolygon net = do

  resolution <- wireResolution <$> ask

  path <- freePolygon resolution

  pure (net, path)


freePolygon n = sequence $ replicate n freePoint


freePoint = liftSMT $ (,) <$> free_ <*> free_


computeStage1 nodes steiner = do

  liftSMT $ query $ do
    result <- checkSat
    case result of

      Sat -> Circuit2D

        <$> sequence
            [ fmap (gate, ) $ Path <$> sequence
                [ (, ) <$> getValue x <*> getValue y | (x, y) <- xs ]
            | (gate, xs) <- Map.assocs nodes
            ]

        <*> sequence
            [ fmap (net, ) $ Path <$> sequence
                [ (, ) <$> getValue x <*> getValue y | (x, y) <- xs ]
            | (net, xs) <- steiner
            ]

      Unsat -> do

        unsat <- getUnsatCore
        liftIO $ sequence_ $ hPutStrLn stderr <$> unsat

        pure $ Circuit2D mempty mempty

      _ -> do

        reason <- getUnknownReason
        liftIO $ hPutStrLn stderr $ show reason

        pure $ Circuit2D mempty mempty


