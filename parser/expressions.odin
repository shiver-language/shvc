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

parse_expression :: proc(
	tokenizer: ^Tokenizer,
	arena: runtime.Allocator,
	allow_struct_literal: bool = true,
) -> ^ast.Spanned_AST {
	err_name :: "expression error"

	operator_stack := stack.make_stack(Op_Item, context.temp_allocator)
	operand_stack := stack.make_stack(^ast.Spanned_AST, context.temp_allocator)

	open_paren_count := 0
	expecting_op := false // flag if we are in infix / postfix

	outer: for {
		token := peek_token(tokenizer, arena)

		#partial switch _ in token.kind {
		case tokens.Semi_Colon, tokens.Close_Bracket, tokens.Comma, tokens.Close_SB:
			break outer

		case tokens.Open_Bracket:
			if expecting_op {
				// check if we are allowed to parse struct literals here
				if !allow_struct_literal do break outer

				// typed literal found
				// eat {
				token = next_token(tokenizer, arena)

				// get type node that is just parsed
				type_node, ok := stack.pop(&operand_stack)
				if !ok {
					panic("compiler error: expecting_op true but operand stack empty")
				}

				// parse content inside
				literal_node := parse_typed_braced_literal(tokenizer, arena, type_node)

				// back to the operand stack
				stack.push(&operand_stack, literal_node)
				expecting_op = true
				continue outer
			}

		case tokens.Close_Paren:
			if open_paren_count == 0 do break outer
		}

		token = next_token(tokenizer, arena)
		start := token.span.start

		#partial switch t in token.kind {
		case tokens.Identifier:
			if expecting_op {
				// we have operand but we hit another identifier after
				// this means the expr ends
				unget_token(tokenizer, token)
				break outer
			}

			next := peek_token(tokenizer, arena)
			operand: ^ast.Spanned_AST

			if _, is_call := next.kind.(tokens.Open_Paren); is_call {
				// eat the (
				bracket_tkn := next_token(tokenizer, arena)

				call_node := new(ast.Spanned_AST, arena)
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
								"expected ',' or ')' in argument list",
								should_panic = true,
							)
						}
						break
					}
				} else {
					next_token(tokenizer, arena)
				}

				call_node.kind = ast.Call {
					target = create_leaf_node(token, arena, tokenizer),
					args   = args_list,
				}
				call_node.span = tokens.Span {
					start = start,
					end   = tokenizer.cursor,
				}
				operand = call_node
			} else {
				operand = create_leaf_node(token, arena, tokenizer)
			}

			operand = parse_postfix_expr(tokenizer, arena, operand)

			stack.push(&operand_stack, operand)
			expecting_op = true

		case tokens.Int_Literal, tokens.Float_Literal, tokens.String_Literal:
			if expecting_op {
				unget_token(tokenizer, token)
				break outer
			}

			operand := create_leaf_node(token, arena, tokenizer)
			operand = parse_postfix_expr(tokenizer, arena, operand)

			stack.push(&operand_stack, operand)
			expecting_op = true

		case tokens.Caret:
			if expecting_op {
				operand, ok := stack.pop(&operand_stack)
				if !ok {
					error.print_error(
						tokenizer.source,
						token.span,
						err_name,
						"internal parser error: operand stack empty for postfix dereference",
						should_panic = true,
					)
				}

				stack.push(&operand_stack, create_unary_node(token, operand, arena))
				expecting_op = true
				continue outer
			} else {
				// prefix pointer types like ^i32
				stack.push(&operator_stack, Op_Item{token = token, is_unary = true})
				expecting_op = false
			}

		case tokens.Ampersand:
			if expecting_op {
				unget_token(tokenizer, token)
				break outer
			}
			// prefix address of operator
			stack.push(&operator_stack, Op_Item{token = token, is_unary = true})
			expecting_op = false

		case tokens.Plus, tokens.Minus:
			if !expecting_op {
				// prefix unary operator like -21
				stack.push(&operator_stack, Op_Item{token = token, is_unary = true})
				expecting_op = false
				continue outer
			}

			// binary infix like a - b
			for !stack.is_empty(&operator_stack) {
				top, _ := stack.peek(&operator_stack)
				if _, ok := top.token.kind.(tokens.Open_Paren); ok do break

				top_prec := precedence(top, tokenizer)
				cur_prec := precedence(Op_Item{token = token, is_unary = false}, tokenizer)

				if top_prec > cur_prec || (!is_right_assoc(token) && top_prec == cur_prec) {
					apply_operator(&operator_stack, &operand_stack, arena, tokenizer)
					continue
				}
				break
			}
			stack.push(&operator_stack, Op_Item{token = token, is_unary = false})
			expecting_op = false

		case tokens.As, tokens.As_Bang:
			if !expecting_op {
				error.print_error(
					tokenizer.source,
					token.span,
					err_name,
					"unexpected cast operator without left-hand side expression",
					should_panic = true,
				)
			}

			// pop the lhs we casting rn
			left, ok := stack.pop(&operand_stack)
			if !ok {
				error.print_error(
					tokenizer.source,
					token.span,
					err_name,
					"missing left operand for cast",
					should_panic = true,
				)
			}

			// we gotta see what type it is dont we
			target_type := parse_type(tokenizer, arena)
			_, is_reinterpret := token.kind.(tokens.As_Bang)

			node := new(ast.Spanned_AST, arena)
			node.kind = ast.Cast_Expr {
				expr           = left,
				target_type    = target_type,
				is_reinterpret = is_reinterpret,
			}
			node.span = tokens.Span {
				start = left.span.start,
				end   = tokenizer.cursor,
			}

			stack.push(&operand_stack, node)
			expecting_op = true

		// expecting_op remains false here cuz unary ops
		case tokens.Assign,
		     tokens.Plus_Assign,
		     tokens.Minus_Assign,
		     tokens.Star_Assign,
		     tokens.Slash_Assign,
		     tokens.Star,
		     tokens.Slash,
		     tokens.Equal,
		     tokens.Not_Equal,
		     tokens.Less,
		     tokens.Greater:
			// binary opts
			if !expecting_op {
				error.print_error(
					tokenizer.source,
					token.span,
					err_name,
					"unexpected binary operator",
					should_panic = true,
				)
			}

			for !stack.is_empty(&operator_stack) {
				top, _ := stack.peek(&operator_stack)
				if _, ok := top.token.kind.(tokens.Open_Paren); ok do break

				top_prec := precedence(top, tokenizer)
				cur_prec := precedence(Op_Item{token = token, is_unary = false}, tokenizer)

				if top_prec > cur_prec || (!is_right_assoc(token) && top_prec == cur_prec) {
					apply_operator(&operator_stack, &operand_stack, arena, tokenizer)
					continue
				}
				break
			}
			stack.push(&operator_stack, Op_Item{token = token, is_unary = false})
			expecting_op = false

		case tokens.Open_Paren:
			if expecting_op {
				unget_token(tokenizer, token)
				break outer
			}
			open_paren_count += 1
			stack.push(&operator_stack, Op_Item{token = token, is_unary = false})

			expecting_op = true // closed paren

		case tokens.Close_Paren:
			if !expecting_op {
				error.print_error(
					tokenizer.source,
					token.span,
					err_name,
					"unexpected ')'",
					should_panic = true,
				)
			}
			open_paren_count -= 1
			found_open := false

			for !stack.is_empty(&operator_stack) {
				top, _ := stack.peek(&operator_stack)

				if _, ok := top.token.kind.(tokens.Open_Paren); ok {
					stack.pop(&operator_stack)
					found_open = true
					break
				}
				apply_operator(&operator_stack, &operand_stack, arena, tokenizer)
			}

			if !found_open {
				error.print_error(
					tokenizer.source,
					token.span,
					err_name,
					"unmatched closing parenthesis",
					should_panic = true,
				)
			}
			expecting_op = true // closed paren acts like a completed operand

		case tokens.Open_Bracket:
			if expecting_op {
				unget_token(tokenizer, token)
				break outer
			}

			operand := parse_braced_literal(tokenizer, arena)
			operand = parse_postfix_expr(tokenizer, arena, operand)
			stack.push(&operand_stack, operand)
			expecting_op = true

		case:
			// if we see keywords or tokens we have no idea what it is
			// we should stop parsing now
			unget_token(tokenizer, token)
			break outer
		}
	}

	for !stack.is_empty(&operator_stack) {
		top, _ := stack.peek(&operator_stack)
		if _, ok := top.token.kind.(tokens.Open_Paren); ok {
			error.print_error(
				tokenizer.source,
				top.token.span,
				err_name,
				"unmatched parenthesis",
				should_panic = true,
			)
		}
		if _, ok := top.token.kind.(tokens.Close_Paren); ok {
			error.print_error(
				tokenizer.source,
				top.token.span,
				err_name,
				"unmatched parenthesis",
				should_panic = true,
			)
		}

		apply_operator(&operator_stack, &operand_stack, arena, tokenizer)
	}

	result, ok := stack.pop(&operand_stack)
	if !ok {
		error.print_error(
			tokenizer.source,
			tokens.Span{},
			err_name,
			"expected expression",
			should_panic = true,
		)
	}
	if !stack.is_empty(&operand_stack) {
		error.print_error(
			tokenizer.source,
			tokens.Span{},
			err_name,
			"malformed expression: too many operands",
			should_panic = true,
		)
	}

	return result
}
