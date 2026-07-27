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
import "base:runtime"
import types "stock_types"
import "tokens"

parse_type_from_identifier :: proc(name: string) -> types.Types {
	switch name {
	case "unit":
		return types.Unit{}
	case "bool":
		return types.Bool{}
	case "int":
		return types.Integer{}
	case "i8":
		return types.Integer8{}
	case "i32":
		return types.Integer32{}
	case "i64":
		return types.Integer64{}
	case "f32":
		return types.Float32{}
	case "f64":
		return types.Float64{}
	case "string":
		return types.String{}
	}

	return types.Custom_Type{name = name}
}

parse_type :: proc(tokenizer: ^Tokenizer, arena: runtime.Allocator) -> types.Types {
	err_name :: "type parser error"

	token := next_token(tokenizer, arena)

	#partial switch t in token.kind {
	case tokens.Caret:
		elem_type := parse_type(tokenizer, arena)
		return types.Pointer{elem = new_clone(elem_type, arena)}

	case tokens.Open_SB:
		count_kind := types.Array_Count_Kind.Fixed
		count := 0

		next := peek_token(tokenizer, arena)

		#partial switch nt in next.kind {
		case tokens.Close_SB:
			// []i32
			next_token(tokenizer, arena)
			count_kind = .Slice

		case tokens.Question:
			// [?]i32
			next_token(tokenizer, arena)

			close_tok := next_token(tokenizer, arena)
			if _, ok := close_tok.kind.(tokens.Close_SB); !ok {
				error.print_error(
					tokenizer.source,
					close_tok.span,
					err_name,
					"expected ']' after '?' in array type",
					should_panic = true,
				)
			}

			count_kind = .Infer

		case tokens.Identifier:
			// [dynamic]i32
			if nt.content == "dynamic" {
				next_token(tokenizer, arena)

				close_tok := next_token(tokenizer, arena)
				if _, ok := close_tok.kind.(tokens.Close_SB); !ok {
					error.print_error(
						tokenizer.source,
						close_tok.span,
						err_name,
						"expected ']' after 'dynamic' in array type",
						should_panic = true,
					)
				}

				count_kind = .Dynamic
			} else {
				error.print_error(
					tokenizer.source,
					next.span,
					err_name,
					"expected array count, '?', 'dynamic', or ']'",
					should_panic = true,
				)
			}

		case tokens.Int_Literal:
			// [3]i32
			next_token(tokenizer, arena)

			if nt.content < 0 {
				error.print_error(
					tokenizer.source,
					next.span,
					err_name,
					"array count cannot be negative",
					should_panic = true,
				)
			}

			count = int(nt.content)

			close_tok := next_token(tokenizer, arena)
			if _, ok := close_tok.kind.(tokens.Close_SB); !ok {
				error.print_error(
					tokenizer.source,
					close_tok.span,
					err_name,
					"expected ']' after array count",
					should_panic = true,
				)
			}

			count_kind = .Fixed

		case:
			error.print_error(
				tokenizer.source,
				next.span,
				err_name,
				"expected array count, '?', 'dynamic', or ']'",
				should_panic = true,
			)
		}

		elem_type := parse_type(tokenizer, arena)

		return types.Array {
			count_kind = count_kind,
			count = count,
			elem = new_clone(elem_type, arena),
		}

	case tokens.Identifier:
		return parse_type_from_identifier(t.content)

	case:
		error.print_error(
			tokenizer.source,
			token.span,
			err_name,
			"expected a valid type identifier or type modifier",
			should_panic = true,
		)
	}

	panic("unreachable")
}
