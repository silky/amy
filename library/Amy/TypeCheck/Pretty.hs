module Amy.TypeCheck.Pretty
  ( prettyModule
  , prettyExpr
  ) where

import Data.Foldable (toList)

import Amy.Literal
import Amy.Pretty
import Amy.TypeCheck.AST

mkPrettyType :: Type -> PrettyType ann
mkPrettyType (TyCon name) = PTyDoc $ prettyTypeName name
mkPrettyType (TyVar name _) = PTyDoc $ prettyTypeName name
mkPrettyType (TyFun ty1 ty2) = PTyFun (mkPrettyType ty1) (mkPrettyType ty2)

prettyTypeName :: TypeName -> Doc ann
prettyTypeName (TypeName name _ _) = pretty name

mkPrettyScheme :: Scheme -> PrettyScheme ann
mkPrettyScheme (Forall vars ty) = PForall (pretty . typeNameText <$> vars) (mkPrettyType ty)

prettyModule :: Module -> Doc ann
prettyModule (Module bindings externs typeDeclarations) =
  vcatTwoHardLines
  $ (prettyExtern' <$> externs)
  ++ (prettyTypeDeclaration' <$> typeDeclarations)
  ++ (prettyBinding' <$> bindings)

prettyExtern' :: Extern -> Doc ann
prettyExtern' (Extern name ty) =
  prettyExtern (prettyIdent name) (mkPrettyType ty)

prettyTypeDeclaration' :: TypeDeclaration -> Doc ann
prettyTypeDeclaration' (TypeDeclaration tyName dataCon tyArg) =
  prettyTypeDeclaration (prettyTypeName tyName) (prettyIdent dataCon) (prettyTypeName tyArg)

prettyBinding' :: Binding -> Doc ann
prettyBinding' (Binding ident scheme args _ body) =
  prettyScheme' ident scheme <>
  hardline <>
  prettyBinding (prettyIdent ident) (prettyIdent . typedValue <$> args) (prettyExpr body)

prettyScheme' :: Ident -> Scheme -> Doc ann
prettyScheme' ident scheme = prettyBindingScheme (prettyIdent ident) (mkPrettyScheme scheme)

prettyIdent :: Ident -> Doc ann
prettyIdent (Ident name _ _) = pretty name

prettyExpr :: Expr -> Doc ann
prettyExpr (ELit lit) = pretty $ showLiteral lit
prettyExpr (EVar (Typed _ var)) = prettyIdent var
prettyExpr (EIf (If pred' then' else')) =
  prettyIf (prettyExpr pred') (prettyExpr then') (prettyExpr else')
prettyExpr (ECase (Case scrutinee matches)) =
  prettyCase (prettyExpr scrutinee) (toList $ mkMatch <$> matches)
 where
  mkMatch (Match pat body) = (prettyPattern pat, prettyExpr body)
prettyExpr (ELet (Let bindings body)) =
  prettyLet (prettyBinding' <$> bindings) (prettyExpr body)
prettyExpr (EApp (App f args _)) = sep $ prettyExpr f : (prettyExpr <$> toList args)
prettyExpr (EParens expr) = parens $ prettyExpr expr

prettyPattern :: Pattern -> Doc ann
prettyPattern (PatternLit lit) = pretty $ showLiteral lit
prettyPattern (PatternVar (Typed _ var)) = prettyIdent var