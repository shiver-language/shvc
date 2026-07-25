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

import "ast"
import "base:runtime"
import "stack"
import "tokens"

make_block :: proc(arena: runtime.Allocator) -> ^ast.Block {
	items_ptr := new([dynamic]^ast.Spanned_AST, arena)
	items_ptr^ = make([dynamic]^ast.Spanned_AST, arena)

	block := new(ast.Block, arena)
	block^ = ast.Block {
		items = items_ptr,
	}

	return block
}

make_block_node :: proc(
	block: ^ast.Block,
	span: tokens.Span,
	arena: runtime.Allocator,
) -> ^ast.Spanned_AST {
	node := new(ast.Spanned_AST, arena)
	node.kind = block^
	node.span = span

	return node
}

add_statement_to_block :: proc(block: ^ast.Spanned_AST, statement: ^ast.Spanned_AST) {
	if block == nil || statement == nil {
		panic("internal parser error: nil block or statement in add_statement_to_block")
	}

	block_node, ok := block.kind.(ast.Block)
	if !ok {
		panic("internal parser error: block.kind must be a Block node")
	}

	if block.span.start > statement.span.start {
		block.span.start = statement.span.start
	}
	if block.span.end < statement.span.end {
		block.span.end = statement.span.end
	}
	append(block_node.items, statement)
}

parse_block_body :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> ^ast.Spanned_AST {
	scope_stack := stack.make_stack(^ast.Spanned_AST, context.temp_allocator)

	root_block := make_block(arena)
	start := peek_token(tokenizer, arena).span.start
	root_block_node := make_block_node(root_block, tokens.Span{start = start, end = start}, arena)
	stack.push(&scope_stack, root_block_node)

	for {
		status, _ := parse_statement_into_current_scope(tokenizer, arena, &scope_stack, false)

		if status == .Done {
			break
		}
	}

	if scope_stack.len != 0 {
		panic("internal parser error: block parser ended with non empty scope stack")
	}

	return make_block_node(root_block, tokens.Span{start = start, end = tokenizer.cursor}, arena)
}
