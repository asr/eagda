{-# LANGUAGE CPP #-}

------------------------------------------------------------------------
-- Pretty-printing of Haskell modules
------------------------------------------------------------------------

module Agda.Compiler.MAlonzo.Pretty where

import Data.Generics.Geniplate
import qualified Language.Haskell.Exts.Syntax as HS
import qualified Language.Haskell.Exts.Pretty as HS
import Text.PrettyPrint (empty)

import Agda.Compiler.MAlonzo.Encode
import Agda.Utils.Pretty
import Agda.Utils.Impossible

#include "undefined.h"

prettyPrint :: Pretty a => a -> String
prettyPrint = show . pretty

instance Pretty HS.Module where
  pretty (HS.Module _ m pragmas Nothing Nothing imps decls) =
    vcat [ vcat $ map pretty pragmas
         , text "module" <+> pretty m <+> text "where"
         , text ""
         , vcat $ map pretty imps
         , text ""
         , vcat $ map pretty decls ]
  pretty _ = __IMPOSSIBLE__

instance Pretty HS.ModulePragma where
  pretty (HS.LanguagePragma _ ps) =
    text "{-#" <+> text "LANGUAGE" <+> fsep (punctuate comma $ map pretty ps) <+> text "#-}"
  pretty HS.OptionsPragma{}   = __IMPOSSIBLE__
  pretty HS.AnnModulePragma{} = __IMPOSSIBLE__

instance Pretty HS.ImportDecl where
  pretty HS.ImportDecl{ HS.importModule    = m
                      , HS.importQualified = q
                      , HS.importSrc       = False
                      , HS.importSafe      = False
                      , HS.importPkg       = Nothing
                      , HS.importAs        = Nothing
                      , HS.importSpecs     = specs } =
      hsep [ text "import"
           , if q then text "qualified" else empty
           , pretty m
           , maybe empty prSpecs specs ]
    where prSpecs (hide, specs) =
            hsep [ if hide then text "hiding" else empty
                 , parens $ fsep $ punctuate comma $ map pretty specs ]
  pretty _ = __IMPOSSIBLE__

instance Pretty HS.ImportSpec where
  pretty (HS.IVar x)          = pretty x
  pretty (HS.IThingAll x)     = pretty x <> text "(..)"
  pretty (HS.IThingWith x cs) = pretty x <> parens (hsep $ punctuate comma $ map pretty cs)
  pretty HS.IAbs{}            = __IMPOSSIBLE__

instance Pretty HS.Decl where
  pretty d = case d of
    HS.TypeDecl _ f xs t ->
      sep [ text "type" <+> pretty f <+> fsep (map pretty xs) <+> text "="
          , nest 2 $ pretty t ]
    HS.DataDecl _ newt [] d xs cons derv ->
      sep [ pretty newt <+> pretty d <+> fsep (map pretty xs)
          , nest 2 $ if null cons then empty
                     else text "=" <+> fsep (punctuate (text " |") $ map pretty cons)
          , nest 2 $ prDeriving derv ]
      where
        prDeriving [] = empty
        prDeriving ds = text "deriving" <+> parens (fsep $ punctuate comma $ map prDer ds)
        prDer (d, ts) = pretty (foldl HS.TyApp (HS.TyCon d) ts)
    HS.TypeSig _ fs t ->
      sep [ hsep (punctuate comma (map pretty fs)) <+> text "::"
          , nest 2 $ pretty t ]
    HS.FunBind ms -> vcat $ map pretty ms
    HS.PatBind _ pat rhs wh ->
      prettyWhere wh $
        sep [ pretty pat, nest 2 $ prettyRhs "=" rhs ]
    _ -> __IMPOSSIBLE__

instance Pretty HS.QualConDecl where
  pretty (HS.QualConDecl _ xs [] con) =
    sep [ text "forall" <+> fsep (map pretty xs) <> text "."
        , nest 2 $ pretty con ]
  pretty _ = __IMPOSSIBLE__

instance Pretty HS.ConDecl where
  pretty (HS.ConDecl c ts)        = pretty c <+> fsep (map (prettyPrec 10) ts)
  pretty (HS.InfixConDecl a op b) = pretty (HS.ConDecl op [a, b])
  pretty HS.RecDecl{}             = __IMPOSSIBLE__

instance Pretty HS.Match where
  pretty (HS.Match _ f ps Nothing rhs wh) =
    prettyWhere wh $
      sep [ pretty f <+> fsep (map (prettyPrec 10) ps)
          , nest 2 $ prettyRhs "=" rhs ]
  pretty _ = __IMPOSSIBLE__

prettyWhere :: Maybe HS.Binds -> Doc -> Doc
prettyWhere Nothing  doc = doc
prettyWhere (Just b) doc =
  vcat [ doc, nest 2 $ sep [ text "where", nest 2 $ pretty b ] ]

instance Pretty HS.Pat where
  prettyPrec pr pat =
    case pat of
      HS.PVar x           -> pretty x
      HS.PLit{}           -> text $ HS.prettyPrint pat
      HS.PAsPat x p       -> mparens (pr > 10) $ pretty x <> text "@" <> prettyPrec 11 p
      HS.PWildCard        -> text "_"
      HS.PBangPat p       -> text "!" <> prettyPrec 11 p
      HS.PApp c ps        -> mparens (pr > 9) $ pretty c <+> hsep (map (prettyPrec 10) ps)
      HS.PatTypeSig _ p t -> mparens (pr > 0) $ sep [ pretty p <+> text "::", nest 2 $ pretty t ]
      HS.PIrrPat p        -> mparens (pr > 10) $ text "~" <> prettyPrec 11 p
      _                   -> __IMPOSSIBLE__

prettyRhs :: String -> HS.Rhs -> Doc
prettyRhs eq (HS.UnGuardedRhs e)   = text eq <+> pretty e
prettyRhs eq (HS.GuardedRhss rhss) = vcat $ map (prettyGuardedRhs eq) rhss

prettyGuardedRhs :: String -> HS.GuardedRhs -> Doc
prettyGuardedRhs eq (HS.GuardedRhs _ ss e) =
    sep [ text "|" <+> sep (punctuate comma $ map pretty ss) <+> text eq
        , nest 2 $ pretty e ]

instance Pretty HS.Binds where
  pretty (HS.BDecls ds) = vcat $ map pretty ds
  pretty HS.IPBinds{} = __IMPOSSIBLE__

instance Pretty HS.DataOrNew where
  pretty HS.DataType = text "data"
  pretty HS.NewType  = text "newtype"

instance Pretty HS.TyVarBind where
  pretty (HS.UnkindedVar x) = pretty x
  pretty _ = __IMPOSSIBLE__

instance Pretty HS.Type where
  prettyPrec pr t =
    case t of
      HS.TyForall (Just xs) [] t ->
        mparens (pr > 0) $
          sep [ text "forall" <+> fsep (map pretty xs) <> text "."
              , nest 2 $ pretty t ]
      HS.TyFun a b ->
        mparens (pr > 4) $
          sep [ prettyPrec 5 a <+> text "->", prettyPrec 4 b ]
      HS.TyCon c -> pretty c
      HS.TyVar x -> pretty x
      t@HS.TyApp{} ->
          sep [ prettyPrec 9 f
              , nest 2 $ fsep $ map (prettyPrec 10) ts ]
        where
          f : ts = appView t []
          appView (HS.TyApp a b) as = appView a (b : as)
          appView t as = t : as
      _ -> __IMPOSSIBLE__

instance Pretty HS.Stmt where
  pretty (HS.Qualifier e) = pretty e
  pretty (HS.Generator _ p e) = sep [ pretty p <+> text "<-", nest 2 $ pretty e ]
  pretty HS.LetStmt{} = __IMPOSSIBLE__
  pretty HS.RecStmt{} = __IMPOSSIBLE__

instance Pretty HS.Exp where
  prettyPrec pr e =
    case e of
      HS.Var x -> pretty x
      HS.Con c -> pretty c
      HS.Lit l -> text $ HS.prettyPrint l
      HS.InfixApp a qop b -> mparens (pr > 0) $
        sep [ prettyPrec 1 a
            , pretty qop <+> prettyPrec 1 b ]
      HS.App{} -> mparens (pr > 9) $
        sep [ prettyPrec 9 f
            , nest 2 $ fsep $ map (prettyPrec 10) es ]
        where
          f : es = appView e []
          appView (HS.App f e) es = appView f (e : es)
          appView f es = f : es
      HS.Lambda _ ps e -> mparens (pr > 0) $
        sep [ text "\\" <+> fsep (map (prettyPrec 10) ps) <+> text "->"
            , nest 2 $ pretty e ]
      HS.Let bs e -> mparens (pr > 0) $
        sep [ text "let" <+> pretty bs <+> text "in"
            , pretty e ]
      HS.If a b c -> mparens (pr > 0) $
        sep [ text "if" <+> pretty a
            , nest 2 $ text "then" <+> pretty b
            , nest 2 $ text "else" <+> prettyPrec 1 c ]
      HS.Case e bs -> mparens (pr > 0) $
        vcat [ text "case" <+> pretty e <+> text "of"
             , nest 2 $ vcat $ map pretty bs ]
      HS.ExpTypeSig _ e t -> mparens (pr > 0) $
        sep [ pretty e <+> text "::"
            , nest 2 $ pretty t ]
      HS.NegApp exp -> parens $ text "-" <> pretty exp
      _ -> __IMPOSSIBLE__

instance Pretty HS.Alt where
  pretty (HS.Alt _ pat rhs wh) =
    prettyWhere wh $
      sep [ pretty pat, nest 2 $ prettyRhs "->" rhs ]

instance Pretty HS.ModuleName where
  pretty = text . HS.prettyPrint . encodeModuleName

instance Pretty HS.QName where
  pretty (HS.Qual m x) = text $ HS.prettyPrint $ HS.Qual (encodeModuleName m) x
  pretty q             = text $ HS.prettyPrint q

instance Pretty HS.Name  where pretty = text . HS.prettyPrint
instance Pretty HS.CName where pretty = text . HS.prettyPrint
instance Pretty HS.QOp   where pretty = text . HS.prettyPrint

