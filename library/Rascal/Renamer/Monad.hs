{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Rascal.Renamer.Monad
  ( Renamer
  , runRenamer
  , emptyRenamerState
  , RenamerError(..)
  , freshId
  , addValueToScope
  , addTypeToScope
  , lookupValueInScope
  , lookupValueInScopeOrError
  , lookupTypeInScope
  , withNewScope
  ) where

import Control.Monad.Except
import Control.Monad.State.Strict
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Rascal.Names

newtype Renamer a = Renamer (ExceptT [RenamerError] (State RenamerState) a)
  deriving (Functor, Applicative, Monad, MonadState RenamerState, MonadError [RenamerError])

runRenamer :: RenamerState -> Renamer a -> Either [RenamerError] a
runRenamer initialState (Renamer action) = evalState (runExceptT action) initialState

data RenamerError
  = TypeSignatureLacksBinding !Text
  | BindingLacksTypeSignature !Text
  | UnknownType !Text
  | UnknownVariable !Text
  | VariableShadowed !Text !IdName
  deriving (Show, Eq)

data RenamerState
  = RenamerState
  { renamerStateLastId :: !NameId
    -- ^ Last 'NameId' generated
  , renamerStateValues :: !(Map Text IdName)
    -- ^ Values in scope
  , renamerStateTypes :: !(Map Text IdName)
    -- ^ Type names in scope
  } deriving (Show, Eq)

emptyRenamerState :: RenamerState
emptyRenamerState =
  RenamerState
  { renamerStateLastId = -1
  , renamerStateValues = Map.empty
  , renamerStateTypes = Map.empty
  }

-- | Generate a new 'NameId'
freshId :: Renamer NameId
freshId = do
  modify' (\s -> s { renamerStateLastId = 1 + renamerStateLastId s })
  gets renamerStateLastId

addValueToScope :: IdNameProvenance -> Text -> Renamer IdName
addValueToScope provenance name = do
  nameId <- freshId
  let idName = IdName name nameId provenance
  mExistingId <- lookupValueInScope name
  case mExistingId of
    Just nid -> throwError [VariableShadowed name nid]
    Nothing -> modify' (\s -> s { renamerStateValues = Map.insert name idName (renamerStateValues s) })
  pure idName

addTypeToScope :: Text -> Renamer IdName
addTypeToScope name = do
  nameId <- freshId
  let idName = IdName name nameId TopLevelDefinition
  mExistingId <- lookupTypeInScope name
  case mExistingId of
    Just nid -> throwError [VariableShadowed name nid]
    Nothing -> modify' (\s -> s { renamerStateTypes = Map.insert name idName (renamerStateTypes s) })
  pure idName

lookupValueInScope :: Text -> Renamer (Maybe IdName)
lookupValueInScope name = Map.lookup name <$> gets renamerStateValues

lookupValueInScopeOrError :: Text -> Renamer IdName
lookupValueInScopeOrError name =
  lookupValueInScope name >>= maybe (throwError [UnknownVariable name]) pure

lookupTypeInScope :: Text -> Renamer (Maybe IdName)
lookupTypeInScope name = Map.lookup name <$> gets renamerStateTypes

-- | Runs a 'Renamer' action in a fresh scope and restores the original scope
-- when the action is done.
withNewScope :: Renamer a -> Renamer a
withNewScope action = do
  originalState <- get
  result <- action
  modify'
    (\s -> s
      { renamerStateValues = renamerStateValues originalState
      , renamerStateTypes = renamerStateTypes originalState
      }
    )
  pure result
