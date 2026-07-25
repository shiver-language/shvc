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

parse_postfix_expr :: proc(
	tokenizer: ^Tokenizer,
	arena: runtime.Allocator,
	base: ^ast.Spanned_AST,
) -> ^ast.Spanned_AST {
	err_name :: "postfix expression error"

	result := base

	for {
		next := peek_token(tokenizer, arena)

		#partial switch _ in next.kind {
		case tokens.Dot:
			next_token(tokenizer, arena) // consume .

			field_tok_spanned := next_token(tokenizer, arena)
			field_tok, ok := field_tok_spanned.kind.(tokens.Identifier)
			if !ok {
				error.print_error(
					tokenizer.source,
					field_tok_spanned.span,
					err_name,
					"expected identifier after '.'",
					should_panic = true,
				)
			}

			// method call expr.name()
			if _, is_call := peek_token(tokenizer, arena).kind.(tokens.Open_Paren); is_call {
				next_token(tokenizer, arena) // consume (

				args_list := new([dynamic]^ast.Spanned_AST, arena)
				args_list^ = make([dynamic]^ast.Spanned_AST, arena)

				if _, empty := peek_token(tokenizer, arena).kind.(tokens.Close_Paren); !empty {
					for {
						arg_expr := parse_expression(tokenizer, arena)
						append(args_list, arg_expr)

						sep := next_token(tokenizer, arena)
						#partial switch _ in sep.kind {
						case tokens.Comma:
							continue
						case tokens.Close_Paren:
							break
						case:
							error.print_error(
								tokenizer.source,
								sep.span,
								err_name,
								"expected ',' or ')' in method argument list",
								should_panic = true,
							)
						}

						break
					}
				} else {
					next_token(tokenizer, arena) // consume )
				}

				node := new(ast.AST_Node, arena)
				node^ = ast.Method_Call {
					target = result,
					method = field_tok.content,
					args   = args_list,
				}

				result = new(ast.Spanned_AST, arena)
				result.kind = node^
				result.span = tokens.Span {
					start = base.span.start,
					end   = tokenizer.cursor,
				}
				continue
			}

			// plain field access via expr.name
			node := new(ast.AST_Node, arena)
			node^ = ast.Field_Access {
				target = result,
				field  = field_tok.content,
			}

			result = new(ast.Spanned_AST, arena)
			result.kind = node^
			result.span = tokens.Span {
				start = base.span.start,
				end   = tokenizer.cursor,
			}
			continue

		case tokens.Open_SB:
			next_token(tokenizer, arena) // consume [

			// forms
			// a[i]
			// a[:]
			// a[i:]
			// a[:j]
			// a[i:j]

			start: ^ast.Spanned_AST = nil
			end: ^ast.Spanned_AST = nil

			if _, has_colon_first := peek_token(tokenizer, arena).kind.(tokens.Colon);
			   has_colon_first {
				next_token(tokenizer, arena) // consume :

				if _, closes := peek_token(tokenizer, arena).kind.(tokens.Close_SB); !closes {
					end = parse_expression(tokenizer, arena)
				}

				close_tok := next_token(tokenizer, arena)
				if _, ok := close_tok.kind.(tokens.Close_SB); !ok {
					error.print_error(
						tokenizer.source,
						close_tok.span,
						err_name,
						"expected ']' after slice expression",
						should_panic = true,
					)
				}

				node := new(ast.AST_Node, arena)
				node^ = ast.Slice_Expr {
					target = result,
					start  = nil,
					end    = end,
				}

				result = new(ast.Spanned_AST, arena)
				result.kind = node^
				result.span = tokens.Span {
					start = base.span.start,
					end   = tokenizer.cursor,
				}
				continue
			}

			// otherwise
			// a[i]
			// a[i:]
			// a[i:j]
			start = parse_expression(tokenizer, arena)

			if _, has_colon := peek_token(tokenizer, arena).kind.(tokens.Colon); has_colon {
				next_token(tokenizer, arena) // consume :

				if _, closes := peek_token(tokenizer, arena).kind.(tokens.Close_SB); !closes {
					end = parse_expression(tokenizer, arena)
				}

				close_tok := next_token(tokenizer, arena)
				if _, ok := close_tok.kind.(tokens.Close_SB); !ok {
					error.print_error(
						tokenizer.source,
						close_tok.span,
						err_name,
						"expected ']' after slice expression",
						should_panic = true,
					)
				}

				node := new(ast.AST_Node, arena)
				node^ = ast.Slice_Expr {
					target = result,
					start  = start,
					end    = end,
				}

				result = new(ast.Spanned_AST, arena)
				result.kind = node^
				result.span = tokens.Span {
					start = base.span.start,
					end   = tokenizer.cursor,
				}
				continue
			}

			close_tok := next_token(tokenizer, arena)
			if _, ok := close_tok.kind.(tokens.Close_SB); !ok {
				error.print_error(
					tokenizer.source,
					close_tok.span,
					err_name,
					"expected ']' after index expression",
					should_panic = true,
				)
			}

			node := new(ast.AST_Node, arena)
			node^ = ast.Index_Expr {
				target = result,
				index  = start,
			}

			result = new(ast.Spanned_AST, arena)
			result.kind = node^
			result.span = tokens.Span {
				start = base.span.start,
				end   = tokenizer.cursor,
			}
			continue

		case:
			return result
		}
	}

	return result
}
