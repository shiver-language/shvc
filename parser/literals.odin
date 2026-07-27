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
import "tokens"

parse_array_literal :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	err_msg :: "array literal error"

	start_token := peek_token(tokenizer, arena)
	items_ptr := new([dynamic]^ast.Spanned_AST, arena)
	items_ptr^ = make([dynamic]^ast.Spanned_AST, arena)

	if _, empty := peek_token(tokenizer, arena).kind.(tokens.Close_Bracket); empty {
		next_token(tokenizer, arena)
	} else {
		for {
			item := parse_expression(tokenizer, arena)
			append(items_ptr, item)

			sep := next_token(tokenizer, arena)

			#partial switch _ in sep.kind {
			case tokens.Comma:
				// allow trailing comma
				if _, is_end := peek_token(tokenizer, arena).kind.(tokens.Close_Bracket); is_end {
					next_token(tokenizer, arena)
					break
				}
				continue

			case tokens.Close_Bracket:
				break

			case:
				error.print_error(
					tokenizer.source,
					sep.span,
					err_msg,
					"expected ',' or '}' in array literal",
					should_panic = true,
				)
			}

			break
		}
	}

	node := new(ast.Spanned_AST, arena)
	node.kind = ast.Array_Literal {
		items = items_ptr,
	}
	node.span = tokens.Span {
		start = start_token.span.start,
		end   = tokenizer.cursor,
	}
	return node
}

parse_struct_literal :: proc(
	tokenizer: ^Tokenizer,
	arena: runtime.Allocator,
	first_token: tokens.Spanned_Token,
) -> ^ast.Spanned_AST {
	err_msg :: "struct literal error"

	fields_ptr := new([dynamic]ast.Spanned_AST, arena)
	fields_ptr^ = make([dynamic]ast.Spanned_AST, arena)

	// eat colon
	next_token(tokenizer, arena)

	first_name := first_token.kind.(tokens.Identifier).content
	first_val := parse_expression(tokenizer, arena)

	struct_literal_field: ast.Spanned_AST
	struct_literal_field.span = tokens.Span {
		start = first_token.span.start,
		end   = first_val.span.end,
	}
	struct_literal_field.kind = ast.Struct_Literal_Field {
		name  = first_name,
		value = first_val,
	}
	append(fields_ptr, struct_literal_field)

	// loop
	for {
		sep := next_token(tokenizer, arena)
		#partial switch _ in sep.kind {
		case tokens.Comma:
			// allow trailing commas: { x: 1, y: 2, }
			if _, is_end := peek_token(tokenizer, arena).kind.(tokens.Close_Bracket); is_end {
				next_token(tokenizer, arena)
				break
			}

			// expect next identifier field name
			ident_tok := next_token(tokenizer, arena)
			ident, is_ident := ident_tok.kind.(tokens.Identifier)
			if !is_ident {
				error.print_error(
					tokenizer.source,
					ident_tok.span,
					err_msg,
					"expected field name identifier in struct literal",
					should_panic = true,
				)
			}

			colon_tok := next_token(tokenizer, arena)
			if _, is_colon := colon_tok.kind.(tokens.Colon); !is_colon {
				error.print_error(
					tokenizer.source,
					colon_tok.span,
					err_msg,
					"expected ':' following field name identifier in struct literal",
					should_panic = true,
				)
			}

			val_expr := parse_expression(tokenizer, arena)

			struct_literal_field.span = tokens.Span {
				start = ident_tok.span.start,
				end   = val_expr.span.end,
			}
			struct_literal_field.kind = ast.Struct_Literal_Field {
				name  = ident.content,
				value = val_expr,
			}
			append(fields_ptr, struct_literal_field)

			continue

		case tokens.Close_Bracket:
			break

		case:
			error.print_error(
				tokenizer.source,
				sep.span,
				err_msg,
				"expected ',' or '}' in struct literal definition",
				should_panic = true,
			)
		}
		break
	}

	node := new(ast.Spanned_AST, arena)
	node.kind = ast.Struct_Literal {
		fields = fields_ptr,
	}
	node.span = tokens.Span {
		start = first_token.span.start,
		end   = tokenizer.cursor,
	}
	return node
}


parse_braced_literal :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	// open bracket is already consumed

	first := next_token(tokenizer, arena)

	// handle empty {}
	if _, empty := first.kind.(tokens.Close_Bracket); empty {
		node := new(ast.Spanned_AST, arena)
		items_ptr := new([dynamic]^ast.Spanned_AST, arena)
		items_ptr^ = make([dynamic]^ast.Spanned_AST, arena)
		node.kind = ast.Array_Literal {
			items = items_ptr,
		}
		node.span = tokens.Span {
			start = first.span.start,
			end   = tokenizer.cursor,
		}
		return node
	}

	// look for this syntax { identifier : ... }
	if _, is_ident := first.kind.(tokens.Identifier); is_ident {
		second := peek_token(tokenizer, arena)
		if _, is_colon := second.kind.(tokens.Colon); is_colon {
			// it is struct literal
			return parse_struct_literal(tokenizer, arena, first)
		}
	}

	// not struct literal, return token and parse as normal
	unget_token(tokenizer, first)
	return parse_array_literal(tokenizer, arena)
}

parse_struct_literal_with_type :: proc(
	tokenizer: ^Tokenizer,
	arena: runtime.Allocator,
	first_token: tokens.Spanned_Token,
	type_node: ^ast.Spanned_AST,
) -> ^ast.Spanned_AST {
	err_msg :: "struct literal error"

	fields_ptr := new([dynamic]ast.Spanned_AST, arena)
	fields_ptr^ = make([dynamic]ast.Spanned_AST, arena)

	// consume : for first k-v mapping
	next_token(tokenizer, arena)

	// extract first field value recursively
	first_name := first_token.kind.(tokens.Identifier).content
	first_val := parse_expression(tokenizer, arena)

	struct_literal_field: ast.Spanned_AST
	struct_literal_field.span = tokens.Span {
		start = first_token.span.start,
		end   = first_val.span.end,
	}
	struct_literal_field.kind = ast.Struct_Literal_Field {
		name  = first_name,
		value = first_val,
	}
	append(fields_ptr, struct_literal_field)

	// loop through remaining fields
	for {
		sep := next_token(tokenizer, arena)
		#partial switch _ in sep.kind {
		case tokens.Comma:
			// trailing comma
			if _, is_end := peek_token(tokenizer, arena).kind.(tokens.Close_Bracket); is_end {
				next_token(tokenizer, arena)
				break
			}

			ident_tok := next_token(tokenizer, arena)
			ident, is_ident := ident_tok.kind.(tokens.Identifier)
			if !is_ident {
				error.print_error(
					tokenizer.source,
					ident_tok.span,
					err_msg,
					"expected field name identifier in struct literal",
					should_panic = true,
				)
			}

			colon_tok := next_token(tokenizer, arena)
			if _, is_colon := colon_tok.kind.(tokens.Colon); !is_colon {
				error.print_error(
					tokenizer.source,
					colon_tok.span,
					err_msg,
					"expected ':' following field name identifier in struct literal",
					should_panic = true,
				)
			}

			val_expr := parse_expression(tokenizer, arena)

			struct_literal_field.span = tokens.Span {
				start = ident_tok.span.start,
				end   = val_expr.span.end,
			}
			struct_literal_field.kind = ast.Struct_Literal_Field {
				name  = ident.content,
				value = val_expr,
			}
			append(fields_ptr, struct_literal_field)
			continue

		case tokens.Close_Bracket:
			break

		case:
			error.print_error(
				tokenizer.source,
				sep.span,
        err_msg,
				"expected ',' or '}' in struct literal definition",
				should_panic = true,
			)
		}
		break
	}

	node := new(ast.Spanned_AST, arena)
	node.kind = ast.Struct_Literal {
		type   = type_node,
		fields = fields_ptr,
	}
	node.span = tokens.Span {
		start = first_token.span.start,
		end   = tokenizer.cursor,
	}
	return node
}

parse_typed_braced_literal :: proc(
	tokenizer: ^Tokenizer,
	arena: runtime.Allocator,
	type_node: ^ast.Spanned_AST,
) -> ^ast.Spanned_AST {
	first := next_token(tokenizer, arena)

	// empty literal Coord{}
	if _, empty := first.kind.(tokens.Close_Bracket); empty {
		node := new(ast.Spanned_AST, arena)
		fields_ptr := new([dynamic]ast.Spanned_AST, arena)
		fields_ptr^ = make([dynamic]ast.Spanned_AST, arena)
		node.kind = ast.Struct_Literal {
			type   = type_node,
			fields = fields_ptr,
		}
		node.span = tokens.Span {
			start = first.span.start,
			end   = tokenizer.cursor,
		}
		return node
	}

	// look ahead for t he field fmt (id + colon)
	if _, is_ident := first.kind.(tokens.Identifier); is_ident {
		second := peek_token(tokenizer, arena)
		if _, is_colon := second.kind.(tokens.Colon); is_colon {
			return parse_struct_literal_with_type(tokenizer, arena, first, type_node)
		}
	}

	unget_token(tokenizer, first)
	return parse_array_literal(tokenizer, arena)
}
