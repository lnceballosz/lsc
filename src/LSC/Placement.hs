
module LSC.Placement where

import Data.Foldable
import qualified Data.Vector as V
import LSC.Types


placement :: NetGraph -> LSC Stage1
placement (NetGraph name pins _ gates wires) = do

  technology <- ask

  let heightAll = foldr (\ k a -> a + fst (lookupDimensions k technology)) 0 gates
  let columnCount = round $ sqrt $ fromIntegral $ length gates

  result <- place True (space, space * 4) 0 (heightAll `div` columnCount) (toList gates)

  pure $ Circuit2D result mempty


space = 8000

place ascending (x, y) width height gates
  | ascending && y > height
  = place (not ascending) (x + width + space, y) width height gates

place ascending (x, y) width height gates
  | not ascending && y < space * 4
  = place (not ascending) (x + width + space, y) width height gates

place ascending (x, y) width height (gate : gates)
  = do

    (h, w) <- lookupDimensions gate <$> ask
    let points = if ascending then [(x, y), (x + w, y + h)] else [(x, y - h), (x + w, y)]

    let h' = h + div space 4

    (:) (gate, Path points)
      <$> place ascending (x, if ascending then y + h' else y - h') (max w width) height gates

place _ _ _ _ _ = pure []

