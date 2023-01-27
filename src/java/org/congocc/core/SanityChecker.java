package org.congocc.core;

import java.util.*;

import org.congocc.Grammar;
import org.congocc.core.nfa.LexicalStateData;
import org.congocc.parser.*;
import org.congocc.parser.tree.*;

/**
 * This class is what remains of a bunch of horrible legacy code 
 * that was used to build up the data structures for the parser.
 * The way congocc works increasingly is simply to expose the 
 * various data structures to the FreeMarker templates. Most
 * of what this class contains now is a bunch of various sanity checks.
 * There will be a general tendency for this class to shrink and hopefully,
 * to eventually just melt away completely.
 */
public class SanityChecker {

    private Grammar grammar;

    private LexerData lexerData;

    public SanityChecker(Grammar grammar) {
        this.grammar = grammar;
        this.lexerData = grammar.getLexerData();
    }

    /**
     * A visitor that checks whether there is a self-referential loop in a 
     * Regexp reference. It is a much more terse, readable replacement
     * for some ugly legacy code.
     * @author revusky
     */
    class RegexpVisitor extends Node.Visitor {

        private HashSet<RegularExpression> alreadyVisited = new HashSet<>(), currentlyVisiting = new HashSet<>();

        void visit(RegexpRef ref) {
            RegularExpression referredTo = ref.getRegexp();
            if (referredTo != null && !alreadyVisited.contains(referredTo)) {
                if (!currentlyVisiting.contains(referredTo)) {
                    currentlyVisiting.add(referredTo);
                    visit(referredTo);
                    currentlyVisiting.remove(referredTo);
                } else {
                    alreadyVisited.add(referredTo);
                    grammar.addError(ref, "Self-referential loop detected");
                }
            }
        }
    }

    // This method contains various sanity checks and adjustments
    // that have been in the code forever. There is a general need
    // to clean this up because it presents a significant obstacle
    // to progress, since the original code is written in such an opaque manner that it is
    // hard to understand what it does.
    public void doChecks() {

        // Check that non-terminals have all been defined.
        List<NonTerminal> undefinedNTs = grammar.descendants(NonTerminal.class, nt->nt.getProduction() == null);
        for (NonTerminal nt : undefinedNTs) {
            grammar.addError(nt, "Non-terminal " + nt.getName() + " has not been defined.");
        }
        if (!undefinedNTs.isEmpty()) return;

        /*
         * Check whether we have any LOOKAHEADs at non-choice points 
         * REVISIT: Why is this not handled in the grammar spec?
         * The legacy code had some kind of very complex munging going on 
         * in these cases, but serious analysis seems to show that it was not something
         * of any real value.
         */
        for (ExpansionSequence sequence : grammar.descendants(ExpansionSequence.class)) {
            if (sequence.getHasExplicitLookahead() 
               && !sequence.isAtChoicePoint())
            {
                grammar.addError(sequence, "Encountered scanahead at a non-choice location." );
            }

            if (sequence.getHasExplicitScanLimit() && !sequence.isAtChoicePoint()) {
                grammar.addError(sequence, "Encountered an up-to-here marker at a non-choice location.");
            }

            if (sequence.getHasExplicitLookahead() && sequence.getHasSeparateSyntacticLookahead() && sequence.getHasExplicitScanLimit()) {
                grammar.addError(sequence, "An expansion cannot have both syntactic lookahead and a scan limit.");
            }

            if (sequence.getHasExplicitNumericalLookahead() && sequence.getHasExplicitScanLimit()) {
                grammar.addError(sequence, "An expansion cannot have both numerical lookahead and a scan limit.");
            }
            
            if (sequence.getHasExplicitLookahead()) {
                if (sequence.getHasExplicitLookahead()
                    && !sequence.getHasSeparateSyntacticLookahead()
                    && !sequence.getHasScanLimit()
                    && !sequence.getHasExplicitNumericalLookahead() 
                    && sequence.getMaximumSize() > 1) {
                        grammar.addWarning(sequence, "Expansion defaults to a lookahead of 1. In a similar spot in JavaCC 21, it would be an indefinite lookahead here, but this changed in Congo");
                    }
            }
        }
/* REVISIT this later.*/
        for (Expansion exp : grammar.descendants(Expansion.class, Expansion::isScanLimit)) {
            if (!((Expansion) exp.getParent()).isAtChoicePoint()) {
                grammar.addError(exp, "The up-to-here delimiter can only be at a choice point.");
            }
        }

        for (BNFProduction prod : grammar.descendants(BNFProduction.class)) {
            String lexicalStateName = prod.getLexicalState();
            if (lexicalStateName != null && lexerData.getLexicalState(lexicalStateName) == null) {
                grammar.addError(prod, "Lexical state \""
                + lexicalStateName + "\" has not been defined.");
            }

            if (prod.isLeftRecursive()) {
                grammar.addWarning(prod, "Production " + prod.getName() + " is left recursive.");
            }
        }

        for (Expansion exp : grammar.descendants(Expansion.class)) {
            String lexicalStateName = exp.getSpecifiedLexicalState();
            if (lexicalStateName != null && lexerData.getLexicalState(lexicalStateName) == null) {
                grammar.addError(exp, "Lexical state \""
                + lexicalStateName + "\" has not been defined.");
            }
        }

        for (ExpansionChoice choice : grammar.descendants(ExpansionChoice.class)) {
            List<Expansion> choices = choice.childrenOfType(Expansion.class);
            for (int i=0; i < choices.size() -1; i++) {
                Expansion unit = choices.get(i);
                if (unit.isAlwaysSuccessful()) {
                    int numFollowing = choices.size() - i -1;
                    String msg = (numFollowing ==1) ? " The expansion that follows " : "The following " + numFollowing + " expansions ";
                    grammar.addError(unit, "This expansion can match empty input." + msg + "can never be matched.");
                }
            }
        }

        for (Node child : grammar.descendants(Expansion.class, n -> n instanceof OneOrMore || n instanceof ZeroOrMore)) {
            Expansion exp = (Expansion) child;
            String starOrPlus = exp instanceof ZeroOrMore ? "(...)*" : "(...)+";
            if (exp.getNestedExpansion().isAlwaysSuccessful()) {
                Failure failure = exp.getNestedExpansion().firstChildOfType(Failure.class);
                if (failure != null) {
                    grammar.addError(exp, "Expansion inside " + starOrPlus + " always fails! This cannot be right!");
                } else {
                    grammar.addError(exp, "Expansion inside " + starOrPlus + " can be matched by empty input, so it would produce an infinite loop!");
                }
            }
        }

        for (ZeroOrOne zoo : grammar.descendants(ZeroOrOne.class, zoo->zoo.getNestedExpansion().isAlwaysSuccessful())) {
            grammar.addWarning(zoo, "The expansion inside this (...)? construct can be matched by empty input so it is always matched. This may not be your intention.");
        }
   

        // Check that no LookBehind predicates refer to an undefined Production
        for (LookBehind lb : grammar.getAllLookBehinds()) {
            for (String name: lb.getPath()) {
                if (Character.isJavaIdentifierStart(name.codePointAt(0))) {
                    if (grammar.getProductionByName(name) == null) {
                        grammar.addError(lb, "Predicate refers to undefined Non-terminal: " + name);
                    }
                }
            }
        }

        // Check that any lexical state referred to actually exists
        for (RegexpSpec res : grammar.descendants(RegexpSpec.class)) {
            String nextLexicalState = res.getNextLexicalState();
            if (nextLexicalState != null && lexerData.getLexicalState(nextLexicalState) == null) {
                Node lastChild = res.getChild(res.getChildCount()-1);
                grammar.addError(lastChild, "Lexical state \""
                + nextLexicalState + "\" has not been defined.");
            }
        }

        for (RegexpSpec regexpSpec : grammar.descendants(RegexpSpec.class)) {
            if (regexpSpec.getRegexp().matchesEmptyString()) {
                grammar.addError(regexpSpec, "Regular Expression can match empty string. This is not allowed here.");
            }
        }


// Below this point is legacy code that I'm still schlepping around.
// Well, actually, even what is below this point is substantially cleaned up now!

        /*
         * The following loop inserts all names of regular expressions into
         * "namedTokensTable" and "ordered_named_tokens". Duplications are
         * flagged as errors.
         */
        for (TokenProduction tp : grammar.descendants(TokenProduction.class)) { 
            for (RegexpSpec res : tp.getRegexpSpecs()){
                RegularExpression re = res.getRegexp();
                if (!(re instanceof RegexpRef) && re.hasLabel()) {
                    String label = re.getLabel();
                    RegularExpression regexp = grammar.getNamedToken(label);
                    if (regexp != null) {
                        grammar.addInfo(res.getRegexp(),
                                "Token name \"" + label + " is redefined.");
                    } 
                    grammar.addNamedToken(label, re);
                }
            }
        }

        /*
         * The following code checks for duplicate string literal
         * tokens in the same lexical state. This is the result 
         * of refactoring some really grotesque legacy code.
         * Though significantly cleaned up, it is still horrible!
         * TODO: Rewrite this in a simpler manner!
         */
        for (TokenProduction tp : grammar.getAllTokenProductions()) {
            Set<RegularExpression> privateRegexps = new HashSet<>();
            for (RegexpSpec res : tp.getRegexpSpecs()) {
                RegularExpression regexp = res.getRegexp();
                if (regexp instanceof RegexpRef) continue;
                if (regexp.isPrivate()) {
                    privateRegexps.add(regexp);
                    continue;
                }
                if (!(regexp instanceof RegexpStringLiteral)) {
                    lexerData.addRegularExpression(res.getRegexp());
                } else {
                    RegexpStringLiteral stringLiteral = (RegexpStringLiteral) regexp;
                    String image = stringLiteral.getImage();
            // This loop performs the checks and actions with respect to
                    // each lexical state.
                    for (String name : tp.getLexicalStateNames()) {
                        LexicalStateData lsd = lexerData.getLexicalState(name);
                        RegularExpression alreadyPresent = lsd.getStringLiteral(image);
                        if (alreadyPresent == null) {
                            if (stringLiteral.getOrdinal() == 0) {
                                lexerData.addRegularExpression(stringLiteral);
                            }
                            lsd.addStringLiteral(stringLiteral);
                        } 
                        else if (!tp.isExplicit()) {
                            if (alreadyPresent.getTokenProduction() != null && !alreadyPresent.getTokenProduction().getKind().equals("TOKEN")) {
                                String kind = alreadyPresent.getTokenProduction().getKind();
                                grammar.addError(stringLiteral,
                                        "String token \""
                                                + image
                                                + "\" has been defined as a \""
                                                + kind
                                                + "\" token.");
                            } else if (privateRegexps.contains(alreadyPresent)) {
                                grammar.addError(stringLiteral,   
                                     "String token \"" + image
                                     + "\" has been defined as a private regular expression.");
                            } else {
                                // This is now a legitimate reference to an
                                // existing StringLiteralRegexp.
                                stringLiteral.setOrdinal(alreadyPresent.getOrdinal());
                                tp.removeChild(res);
                            }
                        }
                    }
                } 
                if (!regexp.getLabel().equals("")) {
                    grammar.addTokenName(regexp.getOrdinal(), regexp.getLabel());
                }
            }
        }


        //Let's jump out here, I guess.
        if (grammar.getErrorCount() >0) return;

        for (RegexpRef ref : grammar.descendants(RegexpRef.class)) {
            String label = ref.getLabel();
            if (grammar.getExtraTokens().containsKey(label)) continue;
            RegularExpression referenced = grammar.getNamedToken(label);
            if (referenced == null) {
                grammar.addError(ref,  "Undefined lexical token name \"" + label + "\".");
            } else if (ref.getTokenProduction() == null || !ref.getTokenProduction().isExplicit()) {
                if (referenced.isPrivate()) {
                    grammar.addError(ref, "Token name \"" + label + "\" refers to a private (with a #) regular expression.");
                }   else if (!referenced.getTokenProduction().getKind().equals("TOKEN")) {
                    grammar.addError(ref, "Token name \"" + label + "\" refers to a non-token (SKIP, MORE, UNPARSED) regular expression.");
                } 
            } 
        }
        
        for (TokenProduction tp : grammar.descendants(TokenProduction.class)) {
            for (RegexpRef ref : tp.descendants(RegexpRef.class)) {
                RegularExpression rexp = grammar.getNamedToken(ref.getLabel());
                if (rexp != null) {
                    ref.setOrdinal(rexp.getOrdinal());
                    ref.setRegexp(rexp);
                }
            }
        }
        
        for (TokenProduction tp : grammar.descendants(TokenProduction.class)) {
            for (RegexpSpec res : tp.getRegexpSpecs()) {
                if (res.getRegexp() instanceof RegexpRef) {
                    tp.removeChild(res);
                }
            }
        }

        // Check for self-referential loops in regular expressions
        RegexpVisitor reVisitor = new RegexpVisitor();
        for (TokenProduction tp : grammar.getAllTokenProductions()) {
            reVisitor.visit(tp);
        }
    }
}
