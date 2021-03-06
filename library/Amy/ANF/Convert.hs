{-# LANGUAGE OverloadedStrings #-}

module Amy.ANF.Convert
  ( normalizeModule
  ) where

import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Amy.ANF.AST as ANF
import Amy.ANF.Monad
import Amy.Core.AST as C
import Amy.Prim

normalizeModule :: C.Module -> ANF.Module
normalizeModule (C.Module bindings externs typeDeclarations maxId) =
  let
    -- Record top-level names
    topLevelNames =
      (C.bindingName <$> bindings)
      ++ (C.externName <$> externs)

    -- Actual conversion
    typeDeclarations' = convertTypeDeclaration <$> typeDeclarations
    externs' = convertExtern <$> externs
    convertState = anfConvertState (maxId + 1) topLevelNames
  in runANFConvert convertState $ do
    bindings' <- traverse (normalizeBinding (Just "res")) bindings
    pure $ ANF.Module bindings' externs' typeDeclarations'

convertExtern :: C.Extern -> ANF.Extern
convertExtern (C.Extern name ty) = ANF.Extern (convertIdent True name) (convertType ty)

convertTypeDeclaration :: C.TypeDeclaration -> ANF.TypeDeclaration
convertTypeDeclaration (C.TypeDeclaration tyName cons) =
  ANF.TypeDeclaration (convertTyConInfo tyName) (convertDataConstructor <$> cons)

convertDataConstructor :: C.DataConstructor -> ANF.DataConstructor
convertDataConstructor (C.DataConstructor conName id' mTyArg tyCon span' index) =
  ANF.DataConstructor
  { ANF.dataConstructorName = conName
  , ANF.dataConstructorId = id'
  , ANF.dataConstructorArgument = convertTyConInfo <$> mTyArg
  , ANF.dataConstructorType = convertTyConInfo tyCon
  , ANF.dataConstructorSpan = span'
  , ANF.dataConstructorIndex = index
  }

convertDataConInfo :: C.DataConInfo -> ANF.DataConInfo
convertDataConInfo (C.DataConInfo typeDecl dataCon) =
  ANF.DataConInfo (convertTypeDeclaration typeDecl) (convertDataConstructor dataCon)

convertIdent :: Bool -> C.Ident -> ANF.Ident
convertIdent isTopLevel (C.Ident name id') = ANF.Ident name id' isTopLevel

convertIdent' :: C.Ident -> ANFConvert ANF.Ident
convertIdent' ident@(C.Ident name id') =
  ANF.Ident name id' <$> isIdentTopLevel ident

convertScheme :: C.Scheme -> ANF.Scheme
convertScheme (C.Forall vars ty) = ANF.Forall (convertTyVarInfo <$> vars) (convertType ty)

convertType :: C.Type -> ANF.Type
convertType (C.TyCon name) = ANF.TyCon (convertTyConInfo name)
convertType (C.TyVar name) = ANF.TyVar (convertTyVarInfo name)
convertType (C.TyFun ty1 ty2) = ANF.TyFun (convertType ty1) (convertType ty2)

convertTyConInfo :: C.TyConInfo -> ANF.TyConInfo
convertTyConInfo (C.TyConInfo name' id') = ANF.TyConInfo name' id'

convertTypedIdent :: C.Typed C.Ident -> ANFConvert (ANF.Typed ANF.Ident)
convertTypedIdent (C.Typed ty arg) = ANF.Typed (convertType ty) <$> convertIdent' arg

convertTyVarInfo :: C.TyVarInfo -> ANF.TyVarInfo
convertTyVarInfo (C.TyVarInfo name' id') = ANF.TyVarInfo name' id'

normalizeExpr
  :: Text -- ^ Base name for generated variables
  -> C.Expr -- ^ Expression to normalize
  -> (ANF.Expr -> ANFConvert ANF.Expr) -- ^ Logical continuation (TODO: Is this needed?)
  -> ANFConvert ANF.Expr
normalizeExpr _ (C.ELit lit) c = c $ ANF.EVal $ ANF.Lit lit
normalizeExpr name var@C.EVar{} c = normalizeName name var (c . ANF.EVal)
normalizeExpr name expr@(C.ECase (C.Case scrutinee matches)) c =
  normalizeName name scrutinee $ \scrutineeVal -> do
    matches' <- traverse normalizeMatch matches
    let ty = convertType $ expressionType expr
    c $ ANF.ECase (ANF.Case scrutineeVal matches' ty)
normalizeExpr name (C.ELet (C.Let bindings expr)) c = do
  bindings' <- traverse (normalizeBinding Nothing) bindings
  expr' <- normalizeExpr name expr c
  pure $ ANF.ELet $ ANF.Let bindings' expr'
normalizeExpr name (C.EApp (C.App func args retTy)) c =
  normalizeList (normalizeName name) (toList args) $ \argVals ->
  normalizeName name func $ \funcVal -> do
    let retTy' = convertType retTy
    case funcVal of
      (ANF.Lit lit) -> error $ "Encountered lit function application " ++ show lit
      (ANF.Var ident) -> normalizeApp ident argVals retTy' c
normalizeExpr name (C.EParens expr) c = normalizeExpr name expr c

normalizeApp
  :: ANF.Var
  -> [ANF.Val]
  -> ANF.Type
  -> (ANF.Expr -> ANFConvert a)
  -> ANFConvert a
normalizeApp var argVals retTy c =
  case var of
    ANF.VVal (ANF.Typed _ ident) ->
      case Map.lookup (ANF.identId ident) primitiveFunctionsById of
        -- Primitive operation
        Just prim -> c $ ANF.EPrimOp $ ANF.App prim argVals retTy
        -- Default, just a function call
        Nothing -> c $ ANF.EApp $ ANF.App var argVals retTy
    ANF.VCons _ ->
      -- Default, just a function call
      c $ ANF.EApp $ ANF.App var argVals retTy

normalizeTerm :: Text -> C.Expr -> ANFConvert ANF.Expr
normalizeTerm name expr = normalizeExpr name expr pure

normalizeName :: Text -> C.Expr -> (ANF.Val -> ANFConvert ANF.Expr) -> ANFConvert ANF.Expr
normalizeName _ (C.ELit lit) c = c $ ANF.Lit lit
normalizeName name (C.EVar var) c =
  case var of
    C.VVal ident -> do
      ident' <- convertTypedIdent ident
      case ident' of
        -- Top-level values need to be first called as functions
        (ANF.Typed ty@(ANF.TyCon _) (ANF.Ident _ _ True)) ->
          mkNormalizeLet name (ANF.EApp $ ANF.App (ANF.VVal ident') [] ty) ty c
        -- Not a top-level value, just return
        _ -> c $ ANF.Var (ANF.VVal ident')
    C.VCons (C.Typed ty cons) -> do
      let
        cons' = convertDataConInfo cons
        ty' = convertType ty
      c $ ANF.Var (ANF.VCons (ANF.Typed ty' cons'))
normalizeName name expr c = do
  expr' <- normalizeTerm name expr
  let exprType = convertType $ expressionType expr
  mkNormalizeLet name expr' exprType c

mkNormalizeLet :: Text -> ANF.Expr -> ANF.Type -> (ANF.Val -> ANFConvert ANF.Expr) -> ANFConvert ANF.Expr
mkNormalizeLet name expr exprType c = do
  newIdent <- freshIdent name
  body <- c $ ANF.Var (ANF.VVal $ ANF.Typed exprType newIdent)
  pure $ ANF.ELet $ ANF.Let [ANF.Binding newIdent (ANF.Forall [] exprType) [] exprType expr] body

normalizeBinding :: Maybe Text -> C.Binding -> ANFConvert ANF.Binding
normalizeBinding mName (C.Binding ident@(C.Ident name _) scheme args retTy body) = do
  -- If we are given a base name, then use iC. Otherwise use the binding name
  -- as the base name for all sub expressions.
  let subName = fromMaybe name mName
  body' <- normalizeTerm subName body
  ident' <- convertIdent' ident
  let scheme' = convertScheme scheme
  args' <- traverse convertTypedIdent args
  let retTy' = convertType retTy
  pure $ ANF.Binding ident' scheme' args' retTy' body'

normalizeMatch :: C.Match -> ANFConvert ANF.Match
normalizeMatch (C.Match pat body) = do
  pat' <- convertPattern pat
  body' <- normalizeTerm "case" body
  pure $ ANF.Match pat' body'

convertPattern :: C.Pattern -> ANFConvert ANF.Pattern
convertPattern (C.PLit lit) = pure $ ANF.PLit lit
convertPattern (C.PVar var) = ANF.PVar <$> convertTypedIdent var
convertPattern (C.PCons (C.PatCons cons mArg retTy)) = do
  let cons' = convertDataConInfo cons
  mArg' <- traverse convertTypedIdent mArg
  let retTy' = convertType retTy
  pure $ ANF.PCons $ ANF.PatCons cons' mArg' retTy'

-- | Helper for normalizing lists of things
normalizeList :: (Monad m) => (a -> (b -> m c) -> m c) -> [a] -> ([b] -> m c) -> m c
normalizeList _ [] c = c []
normalizeList norm (x:xs) c =
  norm x $ \v -> normalizeList norm xs $ \vs -> c (v:vs)
