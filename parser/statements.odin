/*
   Copyright 2026 Shiver Contributors

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

package parser

import "../error"
import "ast"
import "base:runtime"
import "stack"
import "tokens"

Parse_Status :: enum {
	Continue,
	Done,
}

parse_statement_into_current_scope :: proc(
	tokenizer: ^Tokenizer,
	arena: runtime.Allocator,
	scope_stack: ^stack.Stack(^ast.Spanned_AST),
	is_root: bool,
) -> (
	Parse_Status,
	^ast.Spanned_AST,
) {
	err_name :: "statement error"

	token := next_token(tokenizer, arena)
	start := token.span.start

	if _, eofok := token.kind.(tokens.Eof); eofok {
		if !is_root {
			error.print_error(
				tokenizer.source,
				token.span,
				err_name,
				"unexpected EOF inside block",
				should_panic = true,
			)
		}

		return .Done, nil
	}

	if _, scok := token.kind.(tokens.Semi_Colon); scok {
		return .Continue, nil
	}

	current_scope, stackok := stack.peek(scope_stack)
	if !stackok {
		panic("internal parser error: empty scope stack")
	}

	#partial switch _ in token.kind {
	case tokens.Fn:
		start := token.span.start
		fn := parse_fn_signature(tokenizer, arena)

		fn_node := new(ast.Spanned_AST, arena)
		fn_node.kind = fn.kind
		fn_node.span = tokens.Span {
			start = start,
			end   = fn.span.end,
		}

		add_statement_to_block(current_scope, fn_node)

		bracket_tkn := peek_token(tokenizer, arena)
		if _, obok := bracket_tkn.kind.(tokens.Open_Bracket); obok {
			next_token(tokenizer, arena)
			fn.kind.(ast.Fn_Decl).body.span = bracket_tkn.span
			stack.push(scope_stack, fn.kind.(ast.Fn_Decl).body)
		} else {
			error.print_error(
				tokenizer.source,
				bracket_tkn.span,
				err_name,
				"expected function body",
				should_panic = true,
			)
		}

		return .Continue, fn_node

	case tokens.Struct:
		structure := parse_struct_signature(tokenizer, arena)

		struct_node := new(ast.Spanned_AST, arena)
		struct_node.kind = structure
		struct_node.span = tokens.Span {
			start = start,
			end   = tokenizer.cursor,
		}

		add_statement_to_block(current_scope, struct_node)
		return .Continue, struct_node

	case tokens.Trait:
		trait_decl := parse_trait_decl(tokenizer, arena)
		trait_decl.span = tokens.Span {
			start = start,
			end   = tokenizer.cursor,
		}
		add_statement_to_block(current_scope, trait_decl)
		return .Continue, trait_decl

	case tokens.Open_Bracket:
		new_block := make_block(arena)
		block_node := make_block_node(
			new_block,
			tokens.Span{start = start, end = tokenizer.cursor},
			arena,
		)

		add_statement_to_block(current_scope, block_node)
		stack.push(scope_stack, block_node)
		return .Continue, block_node

	case tokens.Close_Bracket:
		if scope_stack.len <= 1 {
			if is_root {
				error.print_error(
					tokenizer.source,
					token.span,
					err_name,
					"unexpected closing bracket",
					should_panic = true,
				)
			}

			block, ok := stack.pop(scope_stack)
			block.span.end = token.span.end
			return .Done, block
		}

		block, ok := stack.pop(scope_stack)
		block.span.end = token.span.end
		return .Continue, block

	case tokens.Identifier,
	     tokens.Int_Literal,
	     tokens.String_Literal,
	     tokens.Float_Literal,
	     tokens.Open_Paren,
	     tokens.Ampersand,
	     tokens.Caret:
		unget_token(tokenizer, token)
		expr := parse_expression(tokenizer, arena)
		add_statement_to_block(current_scope, expr)
		return .Continue, expr

	case tokens.Val, tokens.Mut:
		unget_token(tokenizer, token)
		var_node := parse_var_decl(tokenizer, arena)
		add_statement_to_block(current_scope, var_node)
		return .Continue, var_node

	case tokens.Defer:
		defer_node := new(ast.Spanned_AST, arena)

		if _, is_block := peek_token(tokenizer, arena).kind.(tokens.Open_Bracket); is_block {
			next_token(tokenizer, arena)

			defer_block := make_block(arena)

			defer_node.kind = ast.Defer_Stmt {
				stmt = make_block_node(
					defer_block,
					tokens.Span{start = start, end = tokenizer.cursor},
					arena,
				),
			}
			defer_node.span = tokens.Span {
				start = start,
				end   = tokenizer.cursor,
			}
			add_statement_to_block(current_scope, defer_node)

			stack.push(scope_stack, defer_node)
		} else {
			expr := parse_expression(tokenizer, arena)

			defer_node.kind = ast.Defer_Stmt {
				stmt = expr,
			}
			defer_node.span = tokens.Span {
				start = start,
				end   = tokenizer.cursor,
			}
			add_statement_to_block(current_scope, defer_node)
		}

		return .Continue, defer_node

	case tokens.Return:
		ret_node := new(ast.Spanned_AST, arena)
		expr: ^ast.Spanned_AST = nil

		// see if theres an expr following return
		next_tok := peek_token(tokenizer, arena)
		#partial switch _ in next_tok.kind {
		case tokens.Semi_Colon, tokens.Close_Bracket, tokens.Eof:
		// remains nil
		case:
			// got an expression to evaluate
			expr = parse_expression(tokenizer, arena)
		}

		ret_node.kind = ast.Return_Stmt {
			expr = expr,
		}
		ret_node.span = tokens.Span {
			start = start,
			end   = tokenizer.cursor,
		}
		add_statement_to_block(current_scope, ret_node)
		return .Continue, ret_node

	case tokens.Continue:
		continue_node := new(ast.Spanned_AST, arena)
		continue_node.kind = ast.Continue_Stmt{}
		continue_node.span = tokens.Span {
			start = start,
			end   = tokenizer.cursor,
		}
		add_statement_to_block(current_scope, continue_node)
		return .Continue, continue_node

	case tokens.Break:
		break_node := new(ast.Spanned_AST, arena)
		break_node.kind = ast.Break_Stmt{}
		break_node.span = tokens.Span {
			start = start,
			end   = tokenizer.cursor,
		}
		add_statement_to_block(current_scope, break_node)
		return .Continue, break_node

	case tokens.If:
		if_node := parse_if_statement(tokenizer, arena)
		if_node.span = tokens.Span {
			start = start,
			end   = if_node.span.end,
		}
		add_statement_to_block(current_scope, if_node)
		return .Continue, if_node

	case tokens.For:
		for_node := parse_for_statement(tokenizer, arena)
		for_node.span = tokens.Span {
			start = start,
			end   = for_node.span.end,
		}
		add_statement_to_block(current_scope, for_node)
		return .Continue, for_node

	case:
		error.print_error(
			tokenizer.source,
			token.span,
			err_name,
			"unexpected token at statement level",
			should_panic = true,
		)
	}

	return .Continue, nil
}

parse_single_statement_after_do :: proc(
	tokenizer: ^Tokenizer,
	arena: runtime.Allocator,
) -> ^ast.Spanned_AST {
	err_name :: "do statement error"

	token := next_token(tokenizer, arena)
	start := token.span.start

	#partial switch _ in token.kind {
	case tokens.Identifier,
	     tokens.Int_Literal,
	     tokens.String_Literal,
	     tokens.Float_Literal,
	     tokens.Open_Paren,
	     tokens.Ampersand,
	     tokens.Caret:
		unget_token(tokenizer, token)
		return parse_expression(tokenizer, arena)

	case tokens.Val, tokens.Mut:
		unget_token(tokenizer, token)
		return parse_var_decl(tokenizer, arena)

	case tokens.Continue:
		node := new(ast.Spanned_AST, arena)
		node.kind = ast.Continue_Stmt{}
		node.span = tokens.Span {
			start = start,
			end   = tokenizer.cursor,
		}
		return node

	case tokens.Break:
		node := new(ast.Spanned_AST, arena)
		node.kind = ast.Break_Stmt{}
		node.span = tokens.Span {
			start = start,
			end   = tokenizer.cursor,
		}
		return node

	case tokens.Defer:
		defer_node := new(ast.Spanned_AST, arena)

		peek_tok := peek_token(tokenizer, arena)
		if _, is_block := peek_tok.kind.(tokens.Open_Bracket); is_block {
			error.print_error(
				tokenizer.source,
				peek_tok.span,
				err_name,
				"block defer is not allowed after 'do'; use 'if cond { defer { ... } }'",
				should_panic = true,
			)
		}

		expr := parse_expression(tokenizer, arena)

		defer_node.kind = ast.Defer_Stmt {
			stmt = expr,
		}
		defer_node.span = tokens.Span {
			start = start,
			end   = tokenizer.cursor,
		}
		return defer_node

	case:
		error.print_error(
			tokenizer.source,
			token.span,
			err_name,
			"expected statement after 'do'",
			should_panic = true,
		)
	}

	panic("unreachable")
}

parse_if_body :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	err_name :: "if statement error"

	next := next_token(tokenizer, arena)

	#partial switch _ in next.kind {
	case tokens.Open_Bracket:
		return parse_block_body(tokenizer, arena)

	case tokens.Do:
		return parse_single_statement_after_do(tokenizer, arena)

	case:
		error.print_error(
			tokenizer.source,
			next.span,
			err_name,
			"expected '{' or 'do' after if condition",
			should_panic = true,
		)
	}

	panic("unreachable")
}

parse_if_statement :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	err_name :: "if statement error"

	span_start_tkn := make([dynamic]^tokens.Span, arena)
	conditions := make([dynamic]^ast.Spanned_AST, arena)
	bodies := make([dynamic]^ast.Spanned_AST, arena)

	final_else: ^ast.Spanned_AST = nil
	start := peek_token(tokenizer, arena)
	// parse first if
	first_cond := parse_expression(tokenizer, arena, false)
	first_body := parse_if_body(tokenizer, arena)

	append(&span_start_tkn, &start.span)
	append(&conditions, first_cond)
	append(&bodies, first_body)

	// parse 0 or more else ifs, then else
	for {
		if _, has_else := peek_token(tokenizer, arena).kind.(tokens.Else); !has_else {
			break
		}

		// consume else
		else_tkn := next_token(tokenizer, arena)

		if _, has_if := peek_token(tokenizer, arena).kind.(tokens.If); has_if {
			// consume if
			if_tkn := next_token(tokenizer, arena)

			cond := parse_expression(tokenizer, arena, false)
			body := parse_if_body(tokenizer, arena)

			append(&span_start_tkn, &if_tkn.span)
			append(&conditions, cond)
			append(&bodies, body)

			continue
		}

		append(&span_start_tkn, &else_tkn.span)

		// plain else
		next := next_token(tokenizer, arena)

		#partial switch _ in next.kind {
		case tokens.Open_Bracket:
			final_else = parse_block_body(tokenizer, arena)

		case tokens.Do:
			final_else = parse_single_statement_after_do(tokenizer, arena)

		case:
			error.print_error(
				tokenizer.source,
				next.span,
				err_name,
				"expected '{', 'do', or 'if' after 'else'",
				should_panic = true,
			)
		}

		break
	}

	// build if statement
	tail := final_else

	for i := len(conditions) - 1; i >= 0; i -= 1 {
		node := new(ast.Spanned_AST, arena)

		end_span := bodies[i].span.end
		if tail != nil {
			end_span = tail.span.end
		}

		node.kind = ast.If_Stmt {
			condition = conditions[i],
			body      = bodies[i],
			else_stmt = tail,
		}
		node.span = tokens.Span {
			start = span_start_tkn[i].start,
			end   = end_span,
		}

		tail = node

		if i == 0 {
			break
		}
	}

	return tail
}

parse_for_body :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	err_name :: "for loop error"

	next := next_token(tokenizer, arena)

	#partial switch _ in next.kind {
	case tokens.Open_Bracket:
		return parse_block_body(tokenizer, arena)

	case tokens.Do:
		return parse_single_statement_after_do(tokenizer, arena)

	case:
		error.print_error(
			tokenizer.source,
			next.span,
			err_name,
			"expected '{' or 'do' after for loop header",
			should_panic = true,
		)
	}

	panic("unreachable")
}

next_is_semicolon :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> bool {
	if _, ok := peek_token(tokenizer, arena).kind.(tokens.Semi_Colon); ok {
		return true
	}
	return false
}

next_is_open_bracket :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> bool {
	if _, ok := peek_token(tokenizer, arena).kind.(tokens.Open_Bracket); ok {
		return true
	}
	return false
}

parse_for_statement :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	err_name :: "for loop error"

	node := new(ast.Spanned_AST, arena)
	for_start := tokenizer.cursor
	// for { ... }
	if _, is_block := peek_token(tokenizer, arena).kind.(tokens.Open_Bracket); is_block {
		body := parse_for_body(tokenizer, arena)

		node.kind = ast.For_Stmt {
			kind = .Infinite,
			body = body,
		}
		node.span = tokens.Span {
			start = for_start,
			end   = body.span.end,
		}
		return node
	}

	// for mut val i: i32 = 0; i < 10; i += 1 { ... }
	next := peek_token(tokenizer, arena)

	if _, is_mut := next.kind.(tokens.Mut); is_mut {
		init := parse_var_decl(tokenizer, arena)

		sc_tok := next_token(tokenizer, arena)
		if _, ok := sc_tok.kind.(tokens.Semi_Colon); !ok {
			error.print_error(
				tokenizer.source,
				sc_tok.span,
				err_name,
				"expected ';' after for-loop initializer",
				should_panic = true,
			)
		}

		condition: ^ast.Spanned_AST = nil
		if _, is_sc := peek_token(tokenizer, arena).kind.(tokens.Semi_Colon); !is_sc {
			condition = parse_expression(tokenizer, arena)
		}

		sc_tok2 := next_token(tokenizer, arena)
		if _, ok := sc_tok2.kind.(tokens.Semi_Colon); !ok {
			error.print_error(
				tokenizer.source,
				sc_tok2.span,
				err_name,
				"expected ';' after for-loop condition",
				should_panic = true,
			)
		}

		post: ^ast.Spanned_AST = nil
		if _, is_body := peek_token(tokenizer, arena).kind.(tokens.Open_Bracket); !is_body {
			post = parse_expression(tokenizer, arena, false)
		}

		body := parse_for_body(tokenizer, arena)

		node.kind = ast.For_Stmt {
			kind      = .C_Style,
			init      = init,
			condition = condition,
			post      = post,
			body      = body,
		}
		node.span = tokens.Span {
			start = for_start,
			end   = body.span.end,
		}

		return node
	}

	if _, is_val := next.kind.(tokens.Val); is_val {
		init := parse_var_decl(tokenizer, arena)

		sc_tok := next_token(tokenizer, arena)
		if _, ok := sc_tok.kind.(tokens.Semi_Colon); !ok {
			error.print_error(
				tokenizer.source,
				sc_tok.span,
				err_name,
				"expected ';' after for-loop initializer",
				should_panic = true,
			)
		}

		condition: ^ast.Spanned_AST = nil
		if _, is_sc := peek_token(tokenizer, arena).kind.(tokens.Semi_Colon); !is_sc {
			condition = parse_expression(tokenizer, arena)
		}

		sc_tok2 := next_token(tokenizer, arena)
		if _, ok := sc_tok2.kind.(tokens.Semi_Colon); !ok {
			error.print_error(
				tokenizer.source,
				sc_tok2.span,
				err_name,
				"expected ';' after for-loop condition",
				should_panic = true,
			)
		}

		post: ^ast.Spanned_AST = nil
		if _, is_body := peek_token(tokenizer, arena).kind.(tokens.Open_Bracket); !is_body {
			post = parse_expression(tokenizer, arena, false)
		}

		body := parse_for_body(tokenizer, arena)

		node.kind = ast.For_Stmt {
			kind      = .C_Style,
			init      = init,
			condition = condition,
			post      = post,
			body      = body,
		}
		node.span = tokens.Span {
			start = for_start,
			end   = body.span.end,
		}
		return node
	}

	first_spanned := next_token(tokenizer, arena)
	first_tok, first_ok := first_spanned.kind.(tokens.Identifier)
	if !first_ok {
		error.print_error(
			tokenizer.source,
			first_spanned.span,
			err_name,
			"expected '{', variable declaration, or iterator name after 'for'",
			should_panic = true,
		)
	}

	// for i, index in array { ... }
	if _, has_comma := peek_token(tokenizer, arena).kind.(tokens.Comma); has_comma {
		next_token(tokenizer, arena) // consume comma

		index_spanned := next_token(tokenizer, arena)
		index_tok, index_ok := index_spanned.kind.(tokens.Identifier)
		if !index_ok {
			error.print_error(
				tokenizer.source,
				index_spanned.span,
				err_name,
				"expected index identifier after ',' in for-in loop",
				should_panic = true,
			)
		}

		in_spanned := next_token(tokenizer, arena)
		if _, in_ok := in_spanned.kind.(tokens.In); !in_ok {
			error.print_error(
				tokenizer.source,
				in_spanned.span,
				err_name,
				"expected 'in' after for iterator variables",
				should_panic = true,
			)
		}

		iter_expr := parse_expression(tokenizer, arena, false)
		body := parse_for_body(tokenizer, arena)

		node.kind = ast.For_Stmt {
			kind            = .Each,
			iter_value_name = ast.Identifier{first_tok.content},
			iter_index_name = ast.Identifier{index_tok.content},
			iter_expr       = iter_expr,
			body            = body,
		}
		node.span = tokens.Span {
			start = for_start,
			end   = body.span.end,
		}
		return node
	}

	// for i in array { ... }
	if _, has_in := peek_token(tokenizer, arena).kind.(tokens.In); has_in {
		next_token(tokenizer, arena) // consume in

		iter_expr := parse_expression(tokenizer, arena, false)
		body := parse_for_body(tokenizer, arena)

		node.kind = ast.For_Stmt {
			kind            = .Each,
			iter_value_name = ast.Identifier{first_tok.content},
			iter_expr       = iter_expr,
			body            = body,
		}
		node.span = tokens.Span {
			start = for_start,
			end   = body.span.end,
		}
		return node
	}

	// for i = 0; i < 10; i += 1 { ... }
	// we have consumed first identifier
	// put it back and parse
	unget_token(tokenizer, first_spanned)

	init := parse_expression(tokenizer, arena)

	sc_tok1 := next_token(tokenizer, arena)
	if _, ok := sc_tok1.kind.(tokens.Semi_Colon); !ok {
		error.print_error(
			tokenizer.source,
			sc_tok1.span,
			err_name,
			"expected ';' after for-loop initializer or 'in' for iterator loop",
			should_panic = true,
		)
	}

	condition: ^ast.Spanned_AST = nil
	if _, is_sc := peek_token(tokenizer, arena).kind.(tokens.Semi_Colon); !is_sc {
		condition = parse_expression(tokenizer, arena)
	}

	sc_tok2 := next_token(tokenizer, arena)
	if _, ok := sc_tok2.kind.(tokens.Semi_Colon); !ok {
		error.print_error(
			tokenizer.source,
			sc_tok2.span,
			err_name,
			"expected ';' after for-loop condition",
			should_panic = true,
		)
	}

	post: ^ast.Spanned_AST = nil
	if _, is_body := peek_token(tokenizer, arena).kind.(tokens.Open_Bracket); !is_body {
		post = parse_expression(tokenizer, arena, false)
	}

	body := parse_for_body(tokenizer, arena)

	node.kind = ast.For_Stmt {
		kind      = .C_Style,
		init      = init,
		condition = condition,
		post      = post,
		body      = body,
	}
	node.span = tokens.Span {
		start = for_start,
		end   = body.span.end,
	}
	return node
}
