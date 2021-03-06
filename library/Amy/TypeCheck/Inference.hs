{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Amy.TypeCheck.Inference
  ( inferModule
  , inferTopLevel
  , TyEnv
  , emptyEnv
  ) where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Bifunctor (first)
import Data.Foldable (foldl')
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text, pack)
import Data.Traversable (for)

import Amy.Errors
import Amy.Prim
import Amy.Renamer.AST as R
import Amy.Syntax.Located
import Amy.TypeCheck.AST as T

--
-- Type Environment
--

-- | A 'TyEnv' is the typing environment. It contains known names with their
-- type schemes.
data TyEnv
  = TyEnv
  { identTypes :: Map T.Ident T.Scheme
  } deriving (Show, Eq)

emptyEnv :: TyEnv
emptyEnv = TyEnv Map.empty

extendEnvIdent :: TyEnv -> (T.Ident, T.Scheme) -> TyEnv
extendEnvIdent env (x, s) =
  env
  { identTypes = Map.insert x s (identTypes env)
  }

extendEnvIdentList :: TyEnv -> [(T.Ident, T.Scheme)] -> TyEnv
extendEnvIdentList = foldl' extendEnvIdent

-- removeEnv :: TyEnv -> Name -> TyEnv
-- removeEnv (TyEnv env) var = TyEnv (Map.delete var env)

lookupEnvIdent :: T.Ident -> TyEnv -> Maybe T.Scheme
lookupEnvIdent key = Map.lookup key . identTypes

-- mergeEnv :: TyEnv -> TyEnv -> TyEnv
-- mergeEnv (TyEnv a) (TyEnv b) = TyEnv (Map.union a b)

-- mergeEnvs :: [TyEnv] -> TyEnv
-- mergeEnvs = foldl' mergeEnv emptyEnv

--
-- Inference Monad
--

-- | Holds a 'TyEnv' variables in a 'ReaderT' and a 'State' 'Int'
-- counter for producing type variables.
newtype Inference a = Inference (ReaderT TyEnv (StateT Int (Except Error)) a)
  deriving (Functor, Applicative, Monad, MonadReader TyEnv, MonadState Int, MonadError Error)

-- TODO: Don't use Except, use Validation

runInference :: Int -> TyEnv -> Inference a -> Either Error (a, Int)
runInference maxId env (Inference action) = runExcept $ runStateT (runReaderT action env) (maxId + 1)

freshTypeVariable :: Inference T.Type
freshTypeVariable = do
  modify' (+ 1)
  id' <- get
  pure $ T.TyVar (T.TyVarInfo ("t" <> pack (show id')) id' TyVarGenerated)

-- | Extends the current typing environment with a list of names and schemes
-- for those names.
extendEnvIdentM :: [(T.Ident, T.Scheme)] -> Inference a -> Inference a
extendEnvIdentM tys = local (flip extendEnvIdentList tys)

-- | Lookup type in the environment
lookupEnvIdentM :: T.Ident -> Inference T.Type
lookupEnvIdentM name = do
  mTy <- asks (lookupEnvIdent name)
  maybe (throwError $ UnboundVariable name) instantiate mTy

-- | Convert a scheme into a type by replacing all the type variables with
-- fresh names. Types are instantiated when they are looked up so we can make
-- constraints with the type variables and not worry about name collisions.
instantiate :: T.Scheme -> Inference T.Type
instantiate (T.Forall as t) = do
  as' <- traverse (const freshTypeVariable) as
  let s = Subst $ Map.fromList $ zip as as'
  return $ substituteType s t

-- | Generalizing a type is the quantification of that type with all of the
-- free variables of the type minus the free variables in the environment. This
-- is like finding the type variables that should be "bound" by the
-- quantification. This is also called finding the "closure" of a type.
generalize :: TyEnv -> T.Type -> T.Scheme
generalize env t  = T.Forall as t
 where
  as = Set.toList $ freeTypeVariables t `Set.difference` freeEnvTypeVariables env

-- | Produces a type scheme from a type by finding all the free type variables
-- in the type, replacing them with sequential letters, and collecting the free
-- type variables in the Forall quantifier.
normalize :: T.Type -> (T.Scheme, Subst)
normalize body =
 ( T.Forall (Map.elems letterMap) (normtype body)
 , Subst $ T.TyVar <$> letterMap
 )
 where
  letterMap =
    Map.fromList
    $ (\(var@(T.TyVarInfo _ id' _), letter) -> (var, T.TyVarInfo letter id' TyVarNotGenerated))
    <$> zip (Set.toList $ freeTypeVariables body) letters

  normtype (T.TyFun a b) = T.TyFun (normtype a) (normtype b)
  normtype (T.TyCon a) = T.TyCon a
  normtype (T.TyVar a) =
    case Map.lookup a letterMap of
      Just x -> T.TyVar x
      Nothing -> error "type variable not in signature"

letters :: [Text]
letters = [1..] >>= fmap pack . flip replicateM ['a'..'z']

-- | A 'Constraint' is a statement that two types should be equal.
newtype Constraint = Constraint { unConstraint :: (T.Type, T.Type) }
  deriving (Show, Eq)

--
-- Inference
--

inferModule :: R.Module -> Either Error T.Module
inferModule (R.Module bindings externs typeDeclarations maxId) = do
  let
    externs' = convertExtern <$> externs
    externSchemes = (\(T.Extern name ty) -> (name, T.Forall [] ty)) <$> externs'
    typeDeclarations' = convertTypeDeclaration <$> typeDeclarations
    primFuncSchemes = primitiveFunctionScheme <$> allPrimitiveFunctions
    env =
      TyEnv
      { identTypes = Map.fromList $ externSchemes ++ primFuncSchemes
      }
  (bindings', maxId') <- inferTopLevel maxId env bindings
  pure (T.Module bindings' externs' typeDeclarations' maxId')

convertExtern :: R.Extern -> T.Extern
convertExtern (R.Extern (Located _ name) ty) = T.Extern (convertIdent name) (convertType ty)

convertTypeDeclaration :: R.TypeDeclaration -> T.TypeDeclaration
convertTypeDeclaration (R.TypeDeclaration tyName cons) =
  T.TypeDeclaration (convertTyConInfo tyName) (convertDataConstructor <$> cons)

convertDataConstructor :: R.DataConstructor -> T.DataConstructor
convertDataConstructor (R.DataConstructor (Located _ conName) id' mTyArg tyName span' index) =
  T.DataConstructor
  { T.dataConstructorName = conName
  , T.dataConstructorId = id'
  , T.dataConstructorArgument = convertTyConInfo <$> mTyArg
  , T.dataConstructorType = convertTyConInfo tyName
  , T.dataConstructorSpan = span'
  , T.dataConstructorIndex = index
  }

convertDataConInfo :: R.DataConInfo -> T.DataConInfo
convertDataConInfo (R.DataConInfo tyDecl dataCon) =
  T.DataConInfo (convertTypeDeclaration tyDecl) (convertDataConstructor dataCon)

dataConstructorScheme :: T.DataConstructor -> T.Scheme
dataConstructorScheme (T.DataConstructor _ _ mTyArg tyName _ _) = T.Forall [] ty
 where
  ty =
    case mTyArg of
      Just tyArg -> T.TyCon tyArg `T.TyFun` T.TyCon tyName
      Nothing -> T.TyCon tyName

primitiveFunctionScheme :: PrimitiveFunction -> (T.Ident, T.Scheme)
primitiveFunctionScheme (PrimitiveFunction _ name id' ty) =
  ( T.Ident name id'
  , T.Forall [] $ foldr1 T.TyFun $ T.TyCon . T.fromPrimTyCon <$> ty
  )

inferTopLevel :: Int -> TyEnv -> [R.Binding] -> Either Error ([T.Binding], Int)
inferTopLevel maxId env bindings = do
  (bindingsAndConstraints, maxId') <- runInference maxId env (inferBindings bindings)
  let (bindings', constraints) = unzip bindingsAndConstraints
  subst <- runSolve (concat constraints)
  let
    bindings'' =
      flip fmap bindings' $ \binding ->
        let
          (T.Forall _ ty) = T.bindingType binding
          (scheme', letterSubst) = normalize ty
          binding' = binding { T.bindingType = scheme' }
          subst' = composeSubst subst letterSubst
        in substituteTBinding subst' binding'
  pure (bindings'', maxId')

-- | Infer a group of bindings.
--
-- Binding groups can depend on one another, and even be mutually recursive. We
-- cannot simply just solve them in order. We first have to add all of their
-- types to the environment (either their declared type or a fresh type
-- variable), then we can gather constraints for each binding one by one. We
-- then collect all the constraints and solve them together.
inferBindings :: [R.Binding] -> Inference [(T.Binding, [Constraint])]
inferBindings bindings = do
  -- Generate constraints separately
  bindingsInference <- generateBindingConstraints bindings

  -- Solve constraints together
  env <- ask
  either throwError pure $ solveBindingConstraints env bindingsInference

generateBindingConstraints :: [R.Binding] -> Inference [(T.Binding, [Constraint])]
generateBindingConstraints bindings = do
  -- Record schemes for each binding
  bindingsAndSchemes <- traverse (\binding -> (binding,) <$> generateBindingScheme binding) bindings

  -- Add all the binding type variables to the typing environment and then
  -- collect constraints for all bindings.
  let
    bindingNameSchemes = first (convertIdent . locatedValue . R.bindingName) <$> bindingsAndSchemes
  extendEnvIdentM bindingNameSchemes $ for bindingsAndSchemes $ \(binding, scheme) -> do
    (binding', constraints) <- inferBinding binding
    let
      -- Add the constraint for the binding itself
      (T.Forall _ bindingTy) = T.bindingType binding'
      (T.Forall _ schemeTy) = scheme
      bindingConstraint = Constraint (schemeTy, bindingTy)
    pure (binding', constraints ++ [bindingConstraint])

generateBindingScheme :: R.Binding -> Inference T.Scheme
generateBindingScheme binding =
  maybe
    -- No explicit type annotation, generate a type variable
    (T.Forall [] <$> freshTypeVariable)
    -- There is an explicit type annotation. Use it.
    (pure . convertScheme)
    (R.bindingType binding)

solveBindingConstraints :: TyEnv -> [(T.Binding, [Constraint])] -> Either Error [(T.Binding, [Constraint])]
solveBindingConstraints env bindingsInference = do
  -- Solve all constraints together.
  let
    constraints = concatMap snd bindingsInference
  subst <- runSolve constraints
  pure $ flip fmap bindingsInference $ \(binding, bodyCons) ->
    let
      (T.Forall _ bindingTy) = T.bindingType binding
      scheme = generalize (substituteEnv subst env) (substituteType subst bindingTy)
      binding' = binding { T.bindingType = scheme }
    in (binding', bodyCons)

inferBinding :: R.Binding -> Inference (T.Binding, [Constraint])
inferBinding (R.Binding (Located _ name) _ args body) = do
  argsAndTyVars <- traverse (\(Located _ arg) -> (convertIdent arg,) <$> freshTypeVariable) args
  let argsAndSchemes = (\(arg, t) -> (arg, T.Forall [] t)) <$> argsAndTyVars
  (body', bodyCons) <- extendEnvIdentM argsAndSchemes $ inferExpr body
  let
    returnType = expressionType body'
    bindingTy = foldr1 T.TyFun $ (snd <$> argsAndTyVars) ++ [returnType]
    binding' =
      T.Binding
      { T.bindingName = convertIdent name
        -- Type is placeholder until we can solve all constraints and
        -- generalize to get a scheme. If we were really principled we would
        -- have some new intermediate TCBinding type or something with a Type
        -- instead of a Scheme.
      , T.bindingType = T.Forall [] bindingTy
      , T.bindingArgs = (\(name', tvar) -> T.Typed tvar name') <$> argsAndTyVars
      , T.bindingReturnType = returnType
      , T.bindingBody = body'
      }
  pure (binding', bodyCons)

inferExpr :: R.Expr -> Inference (T.Expr, [Constraint])
inferExpr (R.ELit (Located _ lit)) = pure (T.ELit lit, [])
inferExpr (R.EVar var) =
  case var of
    R.VVal (Located _ valVar) -> do
      let valVar' = convertIdent valVar
      t <- lookupEnvIdentM valVar'
      pure (T.EVar $ T.VVal (T.Typed t valVar'), [])
    R.VCons cons -> do
      let cons' = convertDataConInfo cons
      t <- instantiate $ dataConstructorScheme $ T.dataConInfoCons cons'
      pure (T.EVar $ T.VCons (T.Typed t cons'), [])
inferExpr (R.EIf (R.If pred' then' else')) = do
  (pred'', predCon) <- inferExpr pred'
  (then'', thenCon) <- inferExpr then'
  (else'', elseCon) <- inferExpr else'
  let
    newConstraints =
      [ Constraint (expressionType pred'', T.TyCon $ T.fromPrimTyCon boolTyCon)
      , Constraint (expressionType then'', expressionType else'')
      ]
  pure
    ( T.EIf (T.If pred'' then'' else'')
    , predCon ++ thenCon ++ elseCon ++ newConstraints
    )
inferExpr (R.ECase (R.Case scrutinee matches)) = do
  (scrutinee', scrutineeCons) <- inferExpr scrutinee
  (matches', matchesCons) <- NE.unzip <$> traverse inferMatch matches
  let
    -- Constraint: match patterns have same type as scrutinee
    patternTypes = patternType . T.matchPattern <$> matches'
    scrutineeType = expressionType scrutinee'
    patternConstraints = (\patTy -> Constraint (scrutineeType, patTy)) <$> patternTypes
    -- Constraint: match bodies all have same type. Set all of the body types
    -- equal to the type of the first match body.
    (matchBodyType :| otherMatchBodyTypes) = expressionType . T.matchBody <$> matches'
    bodyConstraints = (\bodyTy -> Constraint (matchBodyType, bodyTy)) <$> otherMatchBodyTypes
  pure
    ( T.ECase (T.Case scrutinee' matches')
    , scrutineeCons ++ concat matchesCons ++ NE.toList patternConstraints ++ bodyConstraints
    )
inferExpr (R.ELet (R.Let bindings expression)) = do
  (bindings', bindingsCons) <- unzip <$> inferBindings bindings
  let
    bindingSchemes = (\binding -> (T.bindingName binding, T.bindingType binding)) <$> bindings'
  (expression', expCons) <- extendEnvIdentM bindingSchemes $ inferExpr expression
  pure
    ( T.ELet (T.Let bindings' expression')
    , concat bindingsCons ++ expCons
    )
inferExpr (R.EApp (R.App func args)) = do
  (func', funcConstraints) <- inferExpr func
  (args', argConstraints) <- NE.unzip <$> traverse inferExpr args
  tyVar <- freshTypeVariable
  let
    argTypes = NE.toList $ expressionType <$> args'
    newConstraint = Constraint (expressionType func', foldr1 T.TyFun (argTypes ++ [tyVar]))
  pure
    ( T.EApp (T.App func' args' tyVar)
    , funcConstraints ++ concat argConstraints ++ [newConstraint]
    )
inferExpr (R.EParens expr) = do
  (expr', constraints) <- inferExpr expr
  pure (T.EParens expr', constraints)

inferMatch :: R.Match -> Inference (T.Match, [Constraint])
inferMatch (R.Match pat body) = do
  (pat', patCons) <- inferPattern pat
  let patScheme = patternScheme pat'
  (body', bodyCons) <- extendEnvIdentM patScheme $ inferExpr body
  pure
    ( T.Match pat' body'
    , patCons ++ bodyCons
    )

inferPattern :: R.Pattern -> Inference (T.Pattern, [Constraint])
inferPattern (R.PLit (Located _ lit)) = pure (T.PLit lit, [])
inferPattern (R.PVar (Located _ ident)) = do
  tvar <- freshTypeVariable
  pure (T.PVar $ T.Typed tvar (convertIdent ident), [])
inferPattern (R.PCons (R.PatCons cons mArg)) = do
  let cons' = convertDataConInfo cons
  consTy <- instantiate $ dataConstructorScheme $ T.dataConInfoCons cons'
  case mArg of
    -- Convert argument and add a constraint on argument plus constructor
    Just arg -> do
      (arg', argCons) <- inferPattern arg
      let argTy = patternType arg'
      retTy <- freshTypeVariable
      let constraint = Constraint (argTy `T.TyFun` retTy, consTy)
      pure
        ( T.PCons $ T.PatCons cons' (Just arg') retTy
        , argCons ++ [constraint]
        )
    -- No argument. The return type is just the data constructor type.
    Nothing ->
      pure
        ( T.PCons $ T.PatCons cons' Nothing consTy
        , []
        )
inferPattern (R.PParens pat) = do
  (pat', patCons) <- inferPattern pat
  pure
    ( T.PParens pat'
    , patCons
    )

patternScheme :: T.Pattern -> [(T.Ident, T.Scheme)]
patternScheme (T.PLit _) = []
patternScheme (T.PVar (T.Typed ty ident)) = [(ident, T.Forall [] ty)]
patternScheme (T.PCons (T.PatCons _ mArg _)) = maybe [] patternScheme mArg
patternScheme (T.PParens pat) = patternScheme pat

--
-- Constraint Solver
--

-- | Constraint solver monad
type Solve a = Except Error a

type Unifier = (Subst, [Constraint])

runSolve :: [Constraint] -> Either Error Subst
runSolve cs = runExcept $ solver (emptySubst, cs)

-- Unification solver
solver :: Unifier -> Solve Subst
solver (su, cs) =
  case cs of
    [] -> return su
    (Constraint (t1, t2): cs0) -> do
      su1 <- unifies t1 t2
      solver (su1 `composeSubst` su, substituteConstraint su1 <$> cs0)

unifies :: T.Type -> T.Type -> Solve Subst
unifies t1 t2 | t1 == t2 = return emptySubst
unifies (T.TyVar v@(T.TyVarInfo _ _ TyVarGenerated)) t = v `bind` t
unifies t (T.TyVar v@(T.TyVarInfo _ _ TyVarGenerated)) = v `bind` t
unifies (T.TyFun t1 t2) (T.TyFun t3 t4) = do
  su1 <- unifies t1 t3
  su2 <- unifies (substituteType su1 t2) (substituteType su1 t4)
  pure (su2 `composeSubst` su1)
unifies t1 t2 = throwError $ UnificationFail t1 t2

bind ::  T.TyVarInfo -> T.Type -> Solve Subst
bind a t
  | t == T.TyVar a = return emptySubst
  | occursCheck a t = throwError $ InfiniteType a t
  | otherwise = return (singletonSubst a t)

occursCheck :: T.TyVarInfo -> T.Type -> Bool
occursCheck a t = a `Set.member` freeTypeVariables t

--
-- Substitutions
--

newtype Subst = Subst (Map T.TyVarInfo T.Type)
  deriving (Eq, Show, Semigroup, Monoid)

emptySubst :: Subst
emptySubst = Subst Map.empty

singletonSubst :: T.TyVarInfo -> T.Type -> Subst
singletonSubst a t = Subst $ Map.singleton a t

composeSubst :: Subst -> Subst -> Subst
(Subst s1) `composeSubst` (Subst s2) = Subst $ Map.map (substituteType (Subst s1)) s2 `Map.union` s1

substituteScheme :: Subst -> T.Scheme -> T.Scheme
substituteScheme (Subst subst) (T.Forall vars ty) = T.Forall vars $ substituteType s' ty
 where
  s' = Subst $ foldr Map.delete subst vars

substituteType :: Subst -> T.Type -> T.Type
substituteType (Subst subst) t@(T.TyVar var) = Map.findWithDefault t var subst
substituteType _ (T.TyCon a) = T.TyCon a
substituteType s (t1 `T.TyFun` t2) = substituteType s t1 `T.TyFun` substituteType s t2

substituteTyped :: Subst -> T.Typed a -> T.Typed a
substituteTyped subst (T.Typed ty x) = T.Typed (substituteType subst ty) x

substituteConstraint :: Subst -> Constraint -> Constraint
substituteConstraint subst (Constraint (t1, t2)) = Constraint (substituteType subst t1, substituteType subst t2)

substituteEnv :: Subst -> TyEnv -> TyEnv
substituteEnv subst (TyEnv identTys) =
  TyEnv
    (Map.map (substituteScheme subst) identTys)

substituteTBinding :: Subst -> T.Binding -> T.Binding
substituteTBinding subst binding =
  binding
  { T.bindingType = substituteScheme subst (T.bindingType binding)
  , T.bindingArgs = substituteTyped subst <$> T.bindingArgs binding
  , T.bindingReturnType = substituteType subst (T.bindingReturnType binding)
  , T.bindingBody = substituteTExpr subst (T.bindingBody binding)
  }

substituteTExpr :: Subst -> T.Expr -> T.Expr
substituteTExpr _ lit@T.ELit{} = lit
substituteTExpr subst (T.EVar var) =
  T.EVar $
    case var of
      T.VVal var' -> T.VVal $ substituteTyped subst var'
      T.VCons (T.Typed ty cons) -> T.VCons (T.Typed (substituteType subst ty) cons)
substituteTExpr subst (T.EIf (T.If pred' then' else')) =
  T.EIf (T.If (substituteTExpr subst pred') (substituteTExpr subst then') (substituteTExpr subst else'))
substituteTExpr subst (T.ECase (T.Case scrutinee matches)) =
  T.ECase (T.Case (substituteTExpr subst scrutinee) (substituteTMatch subst <$> matches))
substituteTExpr subst (T.ELet (T.Let bindings expr)) =
  T.ELet (T.Let (substituteTBinding subst <$> bindings) (substituteTExpr subst expr))
substituteTExpr subst (T.EApp (T.App func args returnType)) =
  T.EApp (T.App (substituteTExpr subst func) (substituteTExpr subst <$> args) (substituteType subst returnType))
substituteTExpr subst (T.EParens expr) = T.EParens (substituteTExpr subst expr)

substituteTMatch :: Subst -> T.Match -> T.Match
substituteTMatch subst (T.Match pat body) =
  T.Match (substituteTPattern subst pat) (substituteTExpr subst body)

substituteTPattern :: Subst -> T.Pattern -> T.Pattern
substituteTPattern _ pat@(T.PLit _) = pat
substituteTPattern subst (T.PVar var) = T.PVar $ substituteTyped subst var
substituteTPattern subst (T.PCons (T.PatCons cons mArg retTy)) =
  let
    mArg' = substituteTPattern subst <$> mArg
    retTy' = substituteType subst retTy
  in T.PCons (T.PatCons cons mArg' retTy')
substituteTPattern subst (T.PParens pat) = T.PParens (substituteTPattern subst pat)

--
-- Free and Active type variables
--

freeTypeVariables :: T.Type -> Set T.TyVarInfo
freeTypeVariables T.TyCon{} = Set.empty
freeTypeVariables (T.TyVar var) = Set.singleton var
freeTypeVariables (t1 `T.TyFun` t2) = freeTypeVariables t1 `Set.union` freeTypeVariables t2

freeSchemeTypeVariables :: T.Scheme -> Set T.TyVarInfo
freeSchemeTypeVariables (T.Forall tvs t) = freeTypeVariables t `Set.difference` Set.fromList tvs

freeEnvTypeVariables :: TyEnv -> Set T.TyVarInfo
freeEnvTypeVariables (TyEnv identTys) =
  foldl' Set.union Set.empty $ freeSchemeTypeVariables <$> Map.elems identTys

--
-- Names
--

convertIdent :: R.Ident -> T.Ident
convertIdent (R.Ident name id') = T.Ident name id'

convertScheme :: R.Scheme -> T.Scheme
convertScheme (R.Forall vars ty) = T.Forall (convertTyVarInfo <$> vars) (convertType ty)

convertType :: R.Type -> T.Type
convertType (R.TyCon info) = T.TyCon (convertTyConInfo info)
convertType (R.TyVar info) = T.TyVar (convertTyVarInfo info)
convertType (R.TyFun ty1 ty2) = T.TyFun (convertType ty1) (convertType ty2)

convertTyConInfo :: R.TyConInfo -> T.TyConInfo
convertTyConInfo (R.TyConInfo name' _ id') = T.TyConInfo name' id'

convertTyVarInfo :: R.TyVarInfo -> T.TyVarInfo
convertTyVarInfo (R.TyVarInfo name' id' _) = T.TyVarInfo name' id' TyVarNotGenerated
