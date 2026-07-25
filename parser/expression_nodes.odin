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

Op_Item :: struct {
	token:    tokens.Spanned_Token,
	is_unary: bool,
}

precedence :: proc(item: Op_Item, tokenizer: ^Tokenizer) -> u8 {
	err_name :: "precedence error"

	if item.is_unary {
		return 6 // high precedence
	}

	#partial switch _ in item.token.kind {
	case tokens.Assign,
	     tokens.Plus_Assign,
	     tokens.Minus_Assign,
	     tokens.Star_Assign,
	     tokens.Slash_Assign:
		return 1
	case tokens.Equal, tokens.Not_Equal:
		return 2
	case tokens.Less, tokens.Greater:
		return 3
	case tokens.Plus, tokens.Minus:
		return 4
	case tokens.Star, tokens.Slash:
		return 5
	case tokens.Ampersand, tokens.Caret:
		return 6
	}
	error.print_error(
		tokenizer.source,
		item.token.span,
		err_name,
		"precedence input token not an operator",
		should_panic = true,
	)
	return 0
}

create_leaf_node :: proc(
	token: tokens.Spanned_Token,
	alloc: runtime.Allocator,
	tokenizer: ^Tokenizer,
) -> ^ast.Spanned_AST { 	// alloc should be in the arena
	err_name :: "leaf node error"

	node := new(ast.Spanned_AST, alloc)
	node.span = token.span
	#partial switch t in token.kind {
	case tokens.Identifier:
		node.kind = ast.Identifier {
			name = t.content,
		}
		return node

	case tokens.Int_Literal:
		node.kind = ast.Int_Literal {
			value = t.content,
		}
		return node

	case tokens.Float_Literal:
		node.kind = ast.Float_Literal {
			value = t.content,
		}
		return node

	case tokens.String_Literal:
		node.kind = ast.String_Literal {
			value = t.content,
		}
		return node

	case:
		error.print_error(
			tokenizer.source,
			token.span,
			err_name,
			"expected an identifier or literal",
			should_panic = true,
		)
		return nil
	}
}

create_binary_node :: proc(
	left: ^ast.Spanned_AST,
	op: tokens.Spanned_Token,
	right: ^ast.Spanned_AST,
	arena: runtime.Allocator,
) -> ^ast.Spanned_AST { 	// do this even need allocation
	node := new(ast.Spanned_AST, arena)
	node.kind = ast.Binary_Op {
		left  = left,
		op    = op.kind,
		right = right,
	}
	node.span = tokens.Span {
		start = left.span.start,
		end   = right.span.end,
	}
	return node
}

create_unary_node :: proc(
	op: tokens.Spanned_Token,
	operand: ^ast.Spanned_AST,
	arena: runtime.Allocator,
) -> ^ast.Spanned_AST {
	node := new(ast.Spanned_AST, arena)
	node.kind = ast.Unary_Op {
		op      = op.kind,
		operand = operand,
	}
	node.span = tokens.Span {
		start = op.span.start,
		end   = operand.span.end,
	}
	return node
}

apply_operator :: proc(
	operator_stack: ^stack.Stack(Op_Item),
	operand_stack: ^stack.Stack(^ast.Spanned_AST),
	arena: runtime.Allocator,
	tokenizer: ^Tokenizer,
) {
	err_name :: "expression error"

	op_item, ostack_ok := stack.pop(operator_stack)
	if !ostack_ok {
		error.print_error(
			tokenizer.source,
			tokens.Span{},
			err_name,
			"missing operator",
			should_panic = true,
		)
	}

	if op_item.is_unary {
		operand, ostack_u_ok := stack.pop(operand_stack)
		if !ostack_u_ok {
			error.print_error(
				tokenizer.source,
				op_item.token.span,
				err_name,
				"missing unary operand",
				should_panic = true,
			)
		}

		stack.push(operand_stack, create_unary_node(op_item.token, operand, arena))
		return
	}

	#partial switch _ in op_item.token.kind {
	case tokens.Assign,
	     tokens.Plus_Assign,
	     tokens.Minus_Assign,
	     tokens.Star_Assign,
	     tokens.Slash_Assign,
	     tokens.Plus,
	     tokens.Minus,
	     tokens.Star,
	     tokens.Slash,
	     tokens.Equal,
	     tokens.Not_Equal,
	     tokens.Less,
	     tokens.Greater:
		right, rok := stack.pop(operand_stack)
		left, lok := stack.pop(operand_stack)

		if !rok || !lok {
			error.print_error(
				tokenizer.source,
				op_item.token.span,
				err_name,
				"missing binary operand",
				should_panic = true,
			)
		}

		stack.push(operand_stack, create_binary_node(left, op_item.token, right, arena))
	case:
		panic("compiler error: unknown operator on stack")
	}
}

is_right_assoc :: proc(token: tokens.Spanned_Token) -> bool {
	#partial switch _ in token.kind {
	case tokens.Assign,
	     tokens.Plus_Assign,
	     tokens.Minus_Assign,
	     tokens.Star_Assign,
	     tokens.Slash_Assign:
		return true
	}
	return false
}

is_unary :: proc(token: tokens.Spanned_Token) -> bool {
	#partial switch _ in token.kind {
	case tokens.Ampersand, tokens.Caret:
		return true
	}
	return false
}
