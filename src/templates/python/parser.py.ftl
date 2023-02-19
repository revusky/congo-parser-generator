[#ftl strict_vars=true]
# Parser parsing package. Generated by ${generated_by}. Do not edit.
[#import "common_utils.inc.ftl" as CU]
[#var MULTIPLE_LEXICAL_STATE_HANDLING = (grammar.lexerData.numLexicalStates >1)]
from enum import Enum, auto, unique
import logging

from .lexer import Lexer
from .tokens import *
from .utils import EMPTY_SET, ListIterator, StringBuilder, _Set, _List, make_frozenset, HashSet

${globals.translateParserImports()}

logger = logging.getLogger(__name__)

#
# Hack to allow token types to be referenced in snippets without
# qualifying
#
globals().update(TokenType.__members__)

class ParseException(Exception):
    def __init__(self, parser, token=None, message=None, expected=None, call_stack=None):
        super().__init__(message)
        self.parser = parser
        if token is None:
            token = parser.last_consumed_token
            if token and token.next:
                token = token.next
        self.token = token
        self.expected = expected
        if call_stack is None:
            call_stack = parser.parsing_stack
        self.call_stack = call_stack[:]

    def __repr__(self):
        if hasattr(self, 'message'):
            return self.message
        parts = []
        if self.token:
            parts.append('unexpected %s (%r) at %s (%d, %d)' %
                         (self.token.type.name, self.token.image,
                          self.token.input_source,
                          self.token.begin_line, self.token.begin_column))
        if self.expected:
            parts.append(', expected %s' % ('' if len(self.expected) == 1 else 'one of '))
            ex = [e.name for e in self.expected]
            parts.append(', '.join(ex))
        return ''.join(parts)

    __str__ = __repr__

def is_lexer(stream_or_lexer):
    return hasattr(stream_or_lexer, 'input_source') and hasattr(stream_or_lexer, 'get_next_token')

UNLIMITED = (1 << 31) - 1

[#if grammar.treeBuildingEnabled]
class NodeScope(list):

    __slots__ = ('parent_scope', 'parser')

    def __init__(self, parser):
        self.parent_scope = parser.current_node_scope
        self.parser = parser
        parser.current_node_scope = self

    @property
    def is_root_Scope(self):
        return self.parent_scope is None

    @property
    def root_node(self):
        ns = self
        while ns.parent_scope:
            ns = ns.parent_scope
        return ns[0] if len(ns) else None

    def peek(self):
        if len(self):
            return self[-1]
        ps = self.parent_scope
        return None if not ps else ps.peek()

    def pop(self):
        return self.parent_scope.pop() if not len(self) else super().pop()

    def poke(self, n):
        if len(self) == 0:
            self.parent_scope.poke(n)
        else:
            self[-1] = n

    def close(self):
        self.parent_scope.extend(self)
        self.parser.current_node_scope = self.parent_scope

    @property
    def nesting_level(self):
        result = 0
        parent = self
        while parent.parent_scope is not None:
            result += 1
            parent = parent.parent_scope
        return result

    def clone(self):
        result = copy.deepcopy(self)
        return result

[/#if]

#
# Class that represents entering a grammar production
#
class NonTerminalCall:

    __slots__ = (
        'source_file',
        'parser',
        'production_name',
        'line', 'column',
        'scan_to_end',
[#if grammar.faultTolerant]
        'follow_set',
[/#if]
    )

    def __init__(self, parser, filename, prodname, line, column):
        self.parser = parser
        self.source_file = filename
        self.production_name = prodname
        self.line = line
        self.column = column
        # We actually only use this when we're working with the LookaheadStack
        self.scan_to_end = parser.scan_to_end
[#if grammar.faultTolerant]
        self.follow_set = parser.outer_follow_set
[/#if]

    def create_stack_trace_element(self):
        return (type(self.parser).__name__,  self.production_name, self.source_file, self.line)

class ParseState:

    __slots__ = ('parser', 'last_consumed', 'parsing_stack',
                 'lexical_state', 'node_scope')

    def __init__(self, parser):
        self.parser = parser
        self.last_consumed = parser.last_consumed_token
        self.parsing_stack = parser.parsing_stack[:]
[#if MULTIPLE_LEXICAL_STATE_HANDLING]
        self.lexical_state = parser.token_source.lexical_state
[/#if]
[#if grammar.treeBuildingEnabled]
        self.node_scope = parser.current_node_scope.clone()
[/#if]

[#if grammar.treeBuildingEnabled]
#
# AST definitions
#
# Parser nodes
#
  [#list globals.sortedNodeClassNames as node]
    [#if !injector.hasInjectedCode(node)]
class ${node}(BaseNode): pass
    [#else]
${globals.translateInjectedClass(node)}
    [/#if]


  [/#list]
[/#if]
class InvalidNode(BaseNode):
    pass


class Parser:

    __slots__ = (
        'token_source',
        'last_consumed_token',
        '_next_token_type',
        'current_lookahead_token',
        'remaining_lookahead',
        'scan_to_end',
        'hit_failure',
        'lookahead_routine_nesting',
        'outer_follow_set',
[#if grammar.faultTolerant]
        'current_follow_set',
[/#if]
        'parsing_stack',
        'lookahead_stack',
        'build_tree',
        'tokens_are_nodes',
        'unparsed_tokens_are_nodes',
        'current_node_scope',
        'parse_state_stack',
        'tolerant_parsing',
        'pending_recovery',
        'debug_fault_tolerant',
        'parsing_problems',
        'currently_parsed_production',
        'current_lookahead_production',
[#var injectedFields = globals.injectedParserFieldNames()]
[#if injectedFields?size > 0]
        # injected fields
[#list injectedFields as fieldName]
        '${fieldName}',
[/#list]
[/#if]
    )

    def __init__(self, input_source_or_lexer):
${globals.translateParserInjections(true)}
        if not is_lexer(input_source_or_lexer):
            self.token_source = Lexer(input_source_or_lexer)
        else:
            self.token_source = input_source_or_lexer
[#if grammar.lexerUsesParser]
        self.token_source.parser = self
[/#if]
        self.last_consumed_token = self.token_source._dummy_start_token
        self._next_token_type = None
        self.current_lookahead_token = None
        self.remaining_lookahead = 0
        self.scan_to_end = False
        self.hit_failure = False
        self.currently_parsed_production = ''
        self.current_lookahead_production = ''
        self.lookahead_routine_nesting = 0
        self.outer_follow_set = set()
        self.parsing_stack = []
        self.lookahead_stack = []
[#if grammar.treeBuildingEnabled]
        self.build_tree = ${CU.bool(grammar.treeBuildingDefault)}
        self.tokens_are_nodes = ${CU.bool(grammar.tokensAreNodes)}
        self.unparsed_tokens_are_nodes = ${CU.bool(grammar.unparsedTokensAreNodes)}
        self.current_node_scope = None
        NodeScope(self)  # attaches to parser
[/#if]
        self.parse_state_stack = []
[#if grammar.faultTolerant]
        self.current_follow_set = set()
        self.tolerant_parsing = True
        self.pending_recovery = False
        self.debug_fault_tolerant = ${CU.bool(grammar.debugFaultTolerant)}
        self.parsing_problems = []

    def add_parsing_problem(self, problem):
        self.parsing_problems.append(problem)

    @property
    def is_tolerant(self):
        return self.tolerant_parsing

    @is_tolerant.setter
    def set_tolerant(self, tolerant):
        self.tolerant_parsing = tolerant
[#else]

    @property
    def is_tolerant(self):
        return False

    @is_tolerant.setter
    def set_tolerant(self, tolerant):
        if tolerant:
            raise NotImplementedError('This parser was not built with fault tolerance support!')
[/#if]

    @property
    def input_source(self):
        return self.token_source.input_source

    def push_last_token_back(self):
[#if grammar.treeBuildingEnabled]
        if self.peek_node() == self.last_consumed_token:
            self.pop_node()
[/#if]
        self.last_consumed_token = self.last_consumed_token.previous_token

    def stash_parse_state(self):
        self.parse_state_stack.append(ParseState(self))

    def pop_parse_state(self):
        return self.parse_state_stack.pop()

    def restore_stashed_parse_state(self):
        state = self.pop_parse_state()
[#if grammar.treeBuildingEnabled]
        self.current_node_scope = state.node_scope
        self.parsing_stack = state.parsing_stack
[/#if]
        if state.last_consumed is not None:
            # REVISIT
            self.last_consumed_token = state.last_consumed
[#if MULTIPLE_LEXICAL_STATE_HANDLING]
        self.token_source.reset(self.last_consumed_token, state.lexical_state)
[#else]
        self.token_source.reset(self.last_consumed_token)
[/#if]

    def push_onto_call_stack(self, method_name, filename, line, column):
        self.parsing_stack.append(NonTerminalCall(self, filename, method_name, line, column))

    def pop_call_stack(self):
        ntc = self.parsing_stack.pop()
        self.currently_parsed_production = ntc.production_name
[#if grammar.faultTolerant]
        self.outer_follow_set = ntc.follow_set
[/#if]

    def restore_call_stack(self, prev_size):
        while len(self.parsing_stack) > prev_size:
            self.pop_call_stack()

    # If the next token is cached, return that
    # Otherwise, go to the lexer
    def next_token(self, tok):
        ts = self.token_source
        result = ts.get_next_token(tok)
        while result.is_unparsed:
     [#list grammar.parserTokenHooks as methodName]
            result = self.${methodName}(result)
     [/#list]
            result = ts.get_next_token(result)
[#list grammar.parserTokenHooks as methodName]
        result = self.${methodName}(result)
[/#list]
        self._next_token_type = None
        return result

    def get_next_token(self):
        return self.get_token(1)

    # If we are in a lookahead, it looks ahead/behind from the current lookahead token
    # Otherwise, it is the last consumed token. If you pass in a negative number, it goes
    # backwards.
    def get_token(self, index):
        t = self.current_lookahead_token or self.last_consumed_token
        if index == 0:
            return t
        elif index > 0:
            for i in range(index):
                t = self.next_token(t)
        else:
            for i in range(-index):
                t = t.previous
                if t is None:
                   break
        return t

    def token_image(self, n):
        return self.get_token(n).image

    def check_next_token_image(self, img):
        return self.token_image(1) == img

    def check_next_token_type(self, tt):
        return self.get_token(1).type == tt

    @property
    def next_token_type(self):
        if self._next_token_type is None:
            self._next_token_type = self.next_token(self.last_consumed_token).type
        return self._next_token_type

    def activate_token_types(self, tt, *types):
        result = False
        att = self.token_source.active_token_types
        if tt not in att:
            result = True
            att.add(tt)
        for tt in types:
            if tt not in att:
                result = True
                att.add(tt)
        self.token_source.reset(self.get_token(0))
        self._next_token_type = None
        return result

    def deactivate_token_types(self, tt, *types):
        result = False
        att = self.token_source.active_token_types
        if tt in att:
            result = True
            att.remove(tt)
        for tt in types:
            if tt in att:
                result = True
                att.remove(tt)
        self.token_source.reset(self.get_token(0))
        self._next_token_type = None
        return result

    def uncache_tokens(self):
        self.token_source.reset(self.get_token(0))

    def fail(self, message):
        if self.current_lookahead_token is None:
            raise ParseException(self, message=message)
        self.hit_failure = True

    def is_in_production(self, name, *prods):
        if self.currently_parsed_production is not None:
            if self.currently_parsed_production == name:
                return True
            for prod in prods:
                if self.currently_parsed_production == prod:
                    return True
        if self.current_lookahead_production is not None:
            if self.current_lookahead_production == name:
                return True
            for prod in prods:
                if self.current_lookahead_production == prod:
                    return True
        it = self.stack_iterator_backward()
        while it.has_next:
            ntc = it.next
            npn = ntc.production_name
            if npn == name:
                return True
            for pn in prods:
                if npn == pn:
                    return True
        return False

[#import "parser_productions.inc.ftl" as ParserCode]
[@ParserCode.Productions /]
[#import "lookahead_routines.inc.ftl" as LookaheadCode]
[@LookaheadCode.Generate/]

[#embed "error_handling.inc.ftl"]

[#if grammar.treeBuildingEnabled]

    @property
    def is_tree_building_enabled(self):
        return self.build_tree

   [#embed "tree_building_code.inc.ftl"]
[#else]
    @property
    def is_tree_building_enabled(self):
        return False

[/#if]
${globals.translateParserInjections(false)}
