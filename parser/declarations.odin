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
import "core:fmt"
import types "stock_types"
import "tokens"

// name ( args ) -> type
// args as in name : type , name : type , ...
parse_fn_signature :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	err_name :: "function declaration error"

	fn := ast.Fn_Decl{}
	args_ptr := new([dynamic]ast.Type_Pair, arena)
	args_ptr^ = make([dynamic]ast.Type_Pair, arena)
	fn.args = args_ptr
	root_block := make_block(arena)

	first_tok_spanned := next_token(tokenizer, arena)
	start := first_tok_spanned.span.start

	first_tok, idok := first_tok_spanned.kind.(tokens.Identifier)
	if !idok do error.print_error(tokenizer.source, first_tok_spanned.span, err_name, "expected function or method name", should_panic = true)

	// TODO: consider whether defining methods with fn struct.method() is a good idea
	if _, has_dot := peek_token(tokenizer, arena).kind.(tokens.Dot); has_dot {
		next_token(tokenizer, arena) // consume .
		method_tok_raw := next_token(tokenizer, arena)
		method_tok, mok := method_tok_raw.kind.(tokens.Identifier)
		if !mok do error.print_error(tokenizer.source, method_tok_raw.span, err_name, "expected method name after '.'", should_panic = true)

		// combine them into a single string identifier
		// this sound like a bandaid solution
		// TODO: reconsider
		fn.name = fmt.aprintf("%s.%s", first_tok.content, method_tok.content, allocator = arena)
	} else {
		fn.name = first_tok.content
	}

	// consume (
	raw_tok := next_token(tokenizer, arena)
	if _, ntok := raw_tok.kind.(tokens.Open_Paren); !ntok {
		error.print_error(
			tokenizer.source,
			raw_tok.span,
			err_name,
			"expected '('",
			should_panic = true,
		)
	}

	end_token := peek_token(tokenizer, arena)

	if _, ptok := peek_token(tokenizer, arena).kind.(tokens.Close_Paren); ptok {
		next_token(tokenizer, arena)
	} else {
		arg_loop: for {
			// handle mut prefix
			tok := next_token(tokenizer, arena)
			is_arg_mut := false
			if _, is_mut := tok.kind.(tokens.Mut); is_mut {
				is_arg_mut = true
				tok = next_token(tokenizer, arena)
			}

			arg_name_tok, name_ok := tok.kind.(tokens.Identifier)
			if !name_ok do error.print_error(tokenizer.source, tok.span, err_name, "expected argument name", should_panic = true)


			raw_tok = next_token(tokenizer, arena)
			if _, colok := raw_tok.kind.(tokens.Colon); !colok {
				error.print_error(
					tokenizer.source,
					raw_tok.span,
					err_name,
					"expected ':'",
					should_panic = true,
				)
			}

			arg_type := parse_type(tokenizer, arena)

			append(
				fn.args,
				ast.Type_Pair{name = arg_name_tok.content, type = arg_type, is_mut = is_arg_mut},
			)

			sep := next_token(tokenizer, arena)
			#partial switch _ in sep.kind {
			case tokens.Comma:
				continue
			case tokens.Close_Paren:
				end_token = sep
				break arg_loop
			case:
				error.print_error(
					tokenizer.source,
					sep.span,
					err_name,
					"expected ',' or ')'",
					should_panic = true,
				)
			}
		}
	}

	fn.ret_type = types.Unit{}

	if _, arok := peek_token(tokenizer, arena).kind.(tokens.Arrow); arok {
		next_token(tokenizer, arena) // consume ->
		end_token = peek_token(tokenizer, arena)
		fn.ret_type = parse_type(tokenizer, arena)
	}

	bracket_tkn := peek_token(tokenizer, arena)

	if _, brok := bracket_tkn.kind.(tokens.Open_Bracket); brok {
		fn.body = make_block_node(root_block, bracket_tkn.span, arena)
	}

	node := new(ast.Spanned_AST, arena)
	node.kind = fn
	node.span = tokens.Span {
		start = start,
		end   = end_token.span.end,
	}
	return node
}

parse_trait_decl :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	err_name :: "trait declaration error"

	name_spanned := next_token(tokenizer, arena)
	name_tok, idok := name_spanned.kind.(tokens.Identifier)
	if !idok do error.print_error(tokenizer.source, name_spanned.span, err_name, "expected trait name", should_panic = true)
	start := name_spanned.span.start

	raw_tok := next_token(tokenizer, arena)
	if _, obok := raw_tok.kind.(tokens.Open_Bracket); !obok {
		error.print_error(
			tokenizer.source,
			raw_tok.span,
			err_name,
			"expected '{' after trait name",
			should_panic = true,
		)
	}

	methods_ptr := new([dynamic]ast.Spanned_AST, arena)
	methods_ptr^ = make([dynamic]ast.Spanned_AST, arena)

	for {
		if _, cbok := peek_token(tokenizer, arena).kind.(tokens.Close_Bracket); cbok {
			next_token(tokenizer, arena) // consume }
			break
		}

		tok := next_token(tokenizer, arena)

		#partial switch _ in tok.kind {
		case tokens.Fn:
			method_sig := parse_fn_signature(tokenizer, arena)
			method_sig.span = tokens.Span {
				start = tok.span.start,
				end   = tokenizer.cursor,
			}
			append(methods_ptr, method_sig^)

		case tokens.Semi_Colon:
			continue

		case:
			error.print_error(
				tokenizer.source,
				tok.span,
				err_name,
				"expected method declaration or '}' inside trait body",
				should_panic = true,
			)
		}
	}

	node := new(ast.Spanned_AST, arena)
	node.kind = ast.Trait_Decl {
		name    = name_tok.content,
		methods = methods_ptr,
	}
	node.span = tokens.Span {
		start = start,
		end   = tokenizer.cursor,
	}
	return node
}

// name { fieldname : type , fieldname : type , }
// optional trailing comma
parse_struct_signature :: proc(
	tokenizer: ^Tokenizer,
	arena: runtime.Allocator,
) -> ast.Struct_Decl {
	err_name :: "struct declaration error"

	structure := ast.Struct_Decl{}

	fields_ptr := new([dynamic]ast.Type_Pair, arena)
	fields_ptr^ = make([dynamic]ast.Type_Pair, arena)
	structure.fields = fields_ptr

	name_tok_raw := next_token(tokenizer, arena)
	name_tok, idok := name_tok_raw.kind.(tokens.Identifier)
	if !idok do error.print_error(tokenizer.source, name_tok_raw.span, err_name, "expected struct name", should_panic = true)

	structure.name = name_tok.content

	raw_tok := next_token(tokenizer, arena)
	if _, obok := raw_tok.kind.(tokens.Open_Bracket); !obok {
		error.print_error(
			tokenizer.source,
			raw_tok.span,
			err_name,
			"expected '{'",
			should_panic = true,
		)
	}

	for {
		if _, cbok := peek_token(tokenizer, arena).kind.(tokens.Close_Bracket); cbok {
			next_token(tokenizer, arena)
			break
		}
		if _, cpok := peek_token(tokenizer, arena).kind.(tokens.Close_Paren); cpok {
			next_token(tokenizer, arena)
			break
		}

		field_name_tok_raw := next_token(tokenizer, arena)
		field_name_tok, fidok := field_name_tok_raw.kind.(tokens.Identifier)
		if !fidok do error.print_error(tokenizer.source, field_name_tok_raw.span, err_name, "expected field name", should_panic = true)

		raw_tok = next_token(tokenizer, arena)
		if _, ok := raw_tok.kind.(tokens.Colon); !ok {
			error.print_error(
				tokenizer.source,
				raw_tok.span,
				err_name,
				"expected ':'",
				should_panic = true,
			)
		}


		raw_tok = next_token(tokenizer, arena)
		field_type_tok, fok := raw_tok.kind.(tokens.Identifier)
		if !fok do error.print_error(tokenizer.source, raw_tok.span, err_name, "expected field type", should_panic = true)

		append(
			structure.fields,
			ast.Type_Pair {
				name = field_name_tok.content,
				type = parse_type_from_identifier(field_type_tok.content),
			},
		)

		sep := next_token(tokenizer, arena)

		#partial switch _ in sep.kind {
		case tokens.Comma:
			continue
		case tokens.Close_Bracket:
			break
		case:
			error.print_error(
				tokenizer.source,
				sep.span,
				err_name,
				"expected ',' or '}'",
				should_panic = true,
			)
		}
	}

	return structure
}

parse_var_decl :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	err_name :: "variable declaration error"

	token := next_token(tokenizer, arena)
	is_mutable := false
	start := token.span.start

	// check if its mut
	if _, ok := token.kind.(tokens.Mut); ok {
		is_mutable = true
		token = next_token(tokenizer, arena)
	}

	// next token is val
	if _, ok := token.kind.(tokens.Val); !ok {
		error.print_error(
			tokenizer.source,
			token.span,
			err_name,
			"expected 'val' keyword",
			should_panic = true,
		)
	}

	// grab the var name
	raw_name_tok := next_token(tokenizer, arena)
	name_tok, varnameok := raw_name_tok.kind.(tokens.Identifier)
	if !varnameok do error.print_error(tokenizer.source, raw_name_tok.span, err_name, "expected variable name to be an identifier", should_panic = true)


	// a : for type
	raw_tkn := next_token(tokenizer, arena)
	if _, colok := raw_tkn.kind.(tokens.Colon); !colok {
		error.print_error(
			tokenizer.source,
			raw_tkn.span,
			err_name,
			"expected ':' after variable name",
			should_panic = true,
		)
	}

	// type parsing
	var_type := parse_type(tokenizer, arena)
	type_end := tokenizer.cursor // capture end of type

	// optional init
	init_kind := ast.Var_Init_Kind.Zero
	value_expr: ^ast.Spanned_AST = nil

	if _, has_assign := peek_token(tokenizer, arena).kind.(tokens.Assign); has_assign {
		next_token(tokenizer, arena) // consume =

		if _, is_question := peek_token(tokenizer, arena).kind.(tokens.Question); is_question {
			next_token(tokenizer, arena) // consume ?
			init_kind = .Undef
		} else {
			value_expr = parse_expression(tokenizer, arena)
			init_kind = .Expr
		}
	}
	// after the init expression

	end: int
	if value_expr != nil {
		end = value_expr.span.end
	} else {
		end = type_end
	}
	// make node
	node := new(ast.Spanned_AST, arena)
	node.kind = ast.Var_Decl {
		name      = name_tok.content,
		type_info = var_type,
		is_mut    = is_mutable,
		init_kind = init_kind,
		init_expr = value_expr,
	}
	node.span = tokens.Span {
		start = start,
		end   = end,
	}

	return node
}
