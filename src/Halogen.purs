module Halogen
  ( Driver()
  , runUI
  , action
  , request
  , module Halogen.Component
  , module Halogen.Effects
  ) where

import Prelude

import Control.Coroutine (Consumer(), await)
import Control.Monad.Aff (Aff())
import Control.Monad.Aff.AVar (AVar(), makeVar, putVar, takeVar)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Free (Free(), runFreeM, liftFI)
import Control.Monad.Rec.Class (forever)
import Control.Monad.State (runState)
import Control.Monad.Trans (lift)

import Data.DOM.Simple.Types (HTMLElement())
import Data.Functor.Coproduct (Coproduct(), coproduct)
import Data.Inject (Inject, inj)
import Data.NaturalTransformation (Natural())
import Data.Tuple (Tuple(..))
import Data.Void (Void())

import Halogen.Component (ComponentP(), renderComponent, queryComponent)
import Halogen.Effects (HalogenEffects())
import Halogen.HTML.Renderer.VirtualDOM (RenderState(), emptyRenderState, renderHTML)
import Halogen.Internal.VirtualDOM (VTree(), createElement, diff, patch)
import Halogen.Query.StateF (StateF(), stateN)
import Halogen.Query.SubscribeF (SubscribeF(), subscribeN)

-- | Type alias for driver functions generated by runUI - a driver takes an
-- | input of the query algebra (`f`) and returns an `Aff` that returns when
-- | query has been fulfilled.
type Driver f eff = Natural f (Aff (HalogenEffects eff))

-- | Type alias used internally to track the driver's persistent state.
type DriverState s =
  { node :: HTMLElement
  , vtree :: VTree
  , state :: s
  , memo :: RenderState
  }

-- | Runs the top level UI component for a Halogen app, returning a generated
-- | HTML element that can be attached to the DOM and a driver function that
-- | can be used to send actions and requests into the component (see the
-- | [`action`](#action), [`request`](#request), and related variations for
-- | more details on querying the driver).
runUI :: forall eff s f o. ComponentP s f (Aff (HalogenEffects eff)) o Void
      -> s
      -> Aff (HalogenEffects eff) { node :: HTMLElement, driver :: Driver f eff }
runUI c s = case renderComponent c s of
    Tuple html s' -> do
      ref <- makeVar
      case renderHTML (driver ref) html emptyRenderState of
        Tuple vtree memo -> do
          let node = createElement vtree
          putVar ref { node: node, vtree: vtree, state: s', memo: memo }
          pure { node: node, driver: driver ref }

  where

  driver :: AVar (DriverState s) -> Driver f eff
  driver ref q = runFreeM (eval ref) (queryComponent c q)

  eval :: AVar (DriverState s)
       -> Natural (Coproduct (StateF s) (Coproduct (SubscribeF f (Aff (HalogenEffects eff))) (Aff (HalogenEffects eff))))
                  (Aff (HalogenEffects eff))
  eval ref = coproduct runStateStep (coproduct runWidgetStep id)
    where
    runWidgetStep :: Natural (SubscribeF f (Aff (HalogenEffects eff))) (Aff (HalogenEffects eff))
    runWidgetStep = subscribeN consumer

    runStateStep :: Natural (StateF s) (Aff (HalogenEffects eff))
    runStateStep i = do
      { node: node, vtree: vtree, state: s, memo: memo } <- takeVar ref
      case runState (stateN i) s of
        Tuple i' s' ->
          case renderComponent c s' of
            Tuple html s'' -> do
              case renderHTML (driver ref) html memo of
                Tuple vtree' memo' -> do
                  node' <- liftEff $ patch (diff vtree vtree') node
                  putVar ref { node: node', vtree: vtree', state: s'', memo: memo' }
                  pure i'

    consumer :: Consumer (f Unit) (Aff (HalogenEffects eff)) Unit
    consumer = forever $ await >>= lift <<< driver ref

-- | Takes a data constructor of `f` and creates an "action", lifting it into
-- | the query algebra `g Unit`. An "action" only causes effects and has
-- | no result value.
-- |
-- | For example:
-- |
-- | ```purescript
-- | data Input a = Tick a
-- |
-- | sendTick :: forall eff. Driver Input eff -> Aff (HalogenEffects eff) Unit
-- | sendTick driver = driver (action Tick)
-- | ```
-- |
-- | Commonly `g` and `f` may be the same type, but when using `Coproduct`
-- | to combine multiple algebras this function performs the work of generating
-- | the correct value for the composite algebra.
action :: forall f g. (Inject f g) => (Unit -> f Unit) -> g Unit
action f = inj (f unit)

-- | Takes a data constructor of `f` and creates a "request", lifting it into
-- | the query algebra `g a`. A "request" can cause effects as well as
-- | fetching some information from a component.
-- |
-- | For example:
-- |
-- | ```purescript
-- | data Input a = GetTickCount (Int -> a)
-- |
-- | getTickCount :: forall eff. Driver Input eff -> Aff (HalogenEffects eff) Int
-- | getTickCount driver = driver (request GetTickCount)
-- | ```
-- |
-- | As with `actionF`, `g` and `f` may be the same type, but when using
-- | `Coproduct` to combine multiple algebras this function performs the work of
-- | generating the correct value for the composite algebra.
request :: forall f g a. (Inject f g) => (forall i. (a -> i) -> f i) -> g a
request f = inj (f id)
