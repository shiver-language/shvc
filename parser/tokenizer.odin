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
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "tokens"

Tokenizer :: struct {
	source:       string, // source code content
	cursor:       int, // byte offset
	peeked_token: tokens.Spanned_Token,
	has_peeked:   bool,
}

new_tokenizer :: proc(allocator: runtime.Allocator) -> ^Tokenizer {
	return new_clone(Tokenizer{}, allocator)
}

inject_src :: proc(tokenizer: ^Tokenizer, src: string) {
	tokenizer.source = src
	tokenizer.cursor = 0
	tokenizer.has_peeked = false
}

peek :: proc(tokenizer: ^Tokenizer) -> rune {
	if is_at_end(tokenizer) do return 0
	r, _ := utf8.decode_rune_in_string(tokenizer.source[tokenizer.cursor:])
	return r
}

is_at_end :: proc(tokenizer: ^Tokenizer) -> bool {
	return tokenizer.cursor >= len(tokenizer.source)
}

advance :: proc(tokenizer: ^Tokenizer, n := 1) {
	for _ in 0 ..< n {
		if is_at_end(tokenizer) do break
		_, width := utf8.decode_rune_in_string(tokenizer.source[tokenizer.cursor:])
		tokenizer.cursor += width
	}
}

is_ident_char :: proc(r: rune) -> bool {
	return unicode.is_alpha(r) || unicode.is_digit(r) || r == '_'
}

unget_token :: proc(tokenizer: ^Tokenizer, token: tokens.Spanned_Token) {
	tokenizer.peeked_token = token
	tokenizer.has_peeked = true
}

peek_next :: proc(tokenizer: ^Tokenizer) -> (result: rune, ok: bool) #optional_ok {
	if is_at_end(tokenizer) do return

	_, width := utf8.decode_rune_in_string(tokenizer.source[tokenizer.cursor:])
	next_idx := tokenizer.cursor + width
	if next_idx >= len(tokenizer.source) do return

	result, _ = utf8.decode_rune_in_string(tokenizer.source[next_idx:])
	ok = true
	return
}

spanned :: proc(tokenizer: ^Tokenizer, start: int, kind: tokens.Token) -> tokens.Spanned_Token {
	return tokens.Spanned_Token {
		kind = kind,
		span = tokens.Span{start = start, end = tokenizer.cursor},
	}
}

scan_token :: proc(tokenizer: ^Tokenizer, allocator: runtime.Allocator) -> tokens.Spanned_Token {
	err_name :: "lexical error"

	comment_start := tokenizer.cursor
	if !skip_whitespace_and_comments(tokenizer) {
		error.print_error(
			tokenizer.source,
			tokens.Span{start = comment_start, end = tokenizer.cursor},
			err_name,
			"unterminated block comment",
			should_panic = true,
		)
	}

	start := tokenizer.cursor

	if is_at_end(tokenizer) {
		return spanned(tokenizer, start, tokens.Eof{})
	}

	char := peek(tokenizer)

	switch char {
	case ':':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Colon{})
	case '-':
		if n, ok := peek_next(tokenizer); ok && n == '>' {
			advance(tokenizer, 2)
			return spanned(tokenizer, start, tokens.Arrow{})
		}
		if n, ok := peek_next(tokenizer); ok && n == '=' {
			advance(tokenizer, 2)
			return spanned(tokenizer, start, tokens.Minus_Assign{})
		}
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Minus{})
	case '^':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Caret{})
	case '&':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Ampersand{})
	case '=':
		if n, ok := peek_next(tokenizer); ok && n == '=' {
			advance(tokenizer, 2)
			return spanned(tokenizer, start, tokens.Equal{})
		}
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Assign{})
	case '!':
		if n, ok := peek_next(tokenizer); ok && n == '=' {
			advance(tokenizer, 2)
			return spanned(tokenizer, start, tokens.Not_Equal{})
		}
		advance(tokenizer)
		error.print_error(
			tokenizer.source,
			tokens.Span{start = start, end = tokenizer.cursor},
			err_name,
			"unexpected character '!'",
			should_panic = true,
		)
	case ',':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Comma{})
	case '?':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Question{})
	case '.':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Dot{})
	case ';':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Semi_Colon{})
	case '+':
		if n, ok := peek_next(tokenizer); ok && n == '=' {
			advance(tokenizer, 2)
			return spanned(tokenizer, start, tokens.Plus_Assign{})
		}
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Plus{})
	case '*':
		if n, ok := peek_next(tokenizer); ok && n == '=' {
			advance(tokenizer, 2)
			return spanned(tokenizer, start, tokens.Star_Assign{})
		}
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Star{})
	case '/':
		if n, ok := peek_next(tokenizer); ok && n == '=' {
			advance(tokenizer, 2)
			return spanned(tokenizer, start, tokens.Slash_Assign{})
		}
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Slash{})
	case '<':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Less{})
	case '>':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Greater{})

	case '(':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Open_Paren{})
	case ')':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Close_Paren{})
	case '{':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Open_Bracket{})
	case '}':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Close_Bracket{})
	case '[':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Open_SB{})
	case ']':
		advance(tokenizer)
		return spanned(tokenizer, start, tokens.Close_SB{})

	case '"':
		advance(tokenizer) // consume opening quote
		b := strings.builder_make(context.temp_allocator)
		defer strings.builder_destroy(&b)

		for !is_at_end(tokenizer) && peek(tokenizer) != '"' {
			c := peek(tokenizer)
			if c == '\\' {
				advance(tokenizer) // consume \
				if is_at_end(tokenizer) {
					error.print_error(
						tokenizer.source,
						tokens.Span{start = start, end = tokenizer.cursor},
						err_name,
						"unterminated escape sequence in string literal",
						should_panic = true,
					)
				}

				escaped_char := peek(tokenizer)
				switch escaped_char {
				case 'n':
					strings.write_rune(&b, '\n')
				case 't':
					strings.write_rune(&b, '\t')
				case 'r':
					strings.write_rune(&b, '\r')
				case '\\':
					strings.write_rune(&b, '\\')
				case '"':
					strings.write_rune(&b, '"')
				case:
					strings.write_rune(&b, escaped_char)
				}
				advance(tokenizer)
				continue
			} else {
				strings.write_rune(&b, c)
				advance(tokenizer)
			}
		}

		if is_at_end(tokenizer) {
			error.print_error(
				tokenizer.source,
				tokens.Span{start = start, end = tokenizer.cursor},
				err_name,
				"unclosed string literal",
				should_panic = true,
			)
		}
		advance(tokenizer) // consume closing quote

		return spanned(
			tokenizer,
			start,
			tokens.String_Literal{strings.clone(strings.to_string(b), allocator)},
		)

	case '`':
		advance(tokenizer) // consume opening backtick
		raw_start := tokenizer.cursor

		for !is_at_end(tokenizer) && peek(tokenizer) != '`' {
			advance(tokenizer)
		}

		if is_at_end(tokenizer) {
			error.print_error(
				tokenizer.source,
				tokens.Span{start = start, end = tokenizer.cursor},
				err_name,
				"unterminated raw string literal",
				should_panic = true,
			)
		}

		raw_str := tokenizer.source[raw_start:tokenizer.cursor]
		advance(tokenizer) // consume closing backtick

		return spanned(tokenizer, start, tokens.String_Literal{strings.clone(raw_str, allocator)})
	}

	if unicode.is_alpha(char) || char == '_' {
		ident_start := tokenizer.cursor
		for !is_at_end(tokenizer) && is_ident_char(peek(tokenizer)) {
			advance(tokenizer)
		}

		text := tokenizer.source[ident_start:tokenizer.cursor]

		switch text {
		case "val":
			return spanned(tokenizer, ident_start, tokens.Val{})
		case "mut":
			return spanned(tokenizer, ident_start, tokens.Mut{})
		case "fn":
			return spanned(tokenizer, ident_start, tokens.Fn{})
		case "trait":
			return spanned(tokenizer, ident_start, tokens.Trait{})
		case "return":
			return spanned(tokenizer, ident_start, tokens.Return{})
		case "if":
			return spanned(tokenizer, ident_start, tokens.If{})
		case "else":
			return spanned(tokenizer, ident_start, tokens.Else{})
		case "do":
			return spanned(tokenizer, ident_start, tokens.Do{})
		case "struct":
			return spanned(tokenizer, ident_start, tokens.Struct{})
		case "for":
			return spanned(tokenizer, ident_start, tokens.For{})
		case "defer":
			return spanned(tokenizer, ident_start, tokens.Defer{})
		case "in":
			return spanned(tokenizer, ident_start, tokens.In{})
		case "break":
			return spanned(tokenizer, ident_start, tokens.Break{})
		case "continue":
			return spanned(tokenizer, ident_start, tokens.Continue{})

		case "as":
			if !is_at_end(tokenizer) && peek(tokenizer) == '!' {
				advance(tokenizer)
				return spanned(tokenizer, ident_start, tokens.As_Bang{})
			}
			return spanned(tokenizer, ident_start, tokens.As{})

		case:
			return spanned(
				tokenizer,
				ident_start,
				tokens.Identifier{strings.clone(text, allocator)},
			)
		}
	}

	if unicode.is_digit(char) {
		num_start := tokenizer.cursor
		is_float := false

		for !is_at_end(tokenizer) &&
		    (unicode.is_digit(peek(tokenizer)) || peek(tokenizer) == '_') {
			advance(tokenizer)
		}

		if !is_at_end(tokenizer) && peek(tokenizer) == '.' {
			if nxt, ok := peek_next(tokenizer); ok && (unicode.is_digit(nxt) || nxt == '_') {
				is_float = true
				advance(tokenizer) // eat period .
				for !is_at_end(tokenizer) &&
				    (unicode.is_digit(peek(tokenizer)) || peek(tokenizer) == '_') {
					advance(tokenizer)
				}
			}
		}

		if !is_at_end(tokenizer) && (peek(tokenizer) == 'e' || peek(tokenizer) == 'E') {
			saved_cursor := tokenizer.cursor
			advance(tokenizer)

			if !is_at_end(tokenizer) && (peek(tokenizer) == '+' || peek(tokenizer) == '-') {
				advance(tokenizer)
			}

			if !is_at_end(tokenizer) &&
			   (unicode.is_digit(peek(tokenizer)) || peek(tokenizer) == '_') {
				is_float = true
				for !is_at_end(tokenizer) &&
				    (unicode.is_digit(peek(tokenizer)) || peek(tokenizer) == '_') {
					advance(tokenizer)
				}
			} else {
				tokenizer.cursor = saved_cursor
			}
		}

		num_str := tokenizer.source[num_start:tokenizer.cursor]
		clean_num_str, _ := strings.remove_all(num_str, "_", context.temp_allocator)

		if is_float {
			val, ok := strconv.parse_f32(clean_num_str)
			if !ok {
				error.print_error(
					tokenizer.source,
					tokens.Span{start = num_start, end = tokenizer.cursor},
					err_name,
					"failed to parse float literal",
					should_panic = true,
				)
			}
			return spanned(tokenizer, num_start, tokens.Float_Literal{val})
		} else {
			val, ok := strconv.parse_int(clean_num_str)
			if !ok {
				error.print_error(
					tokenizer.source,
					tokens.Span{start = num_start, end = tokenizer.cursor},
					err_name,
					"failed to parse integer literal",
					should_panic = true,
				)
			}
			return spanned(tokenizer, num_start, tokens.Int_Literal{cast(i32)val})
		}
	}

	advance(tokenizer)
	error.print_error(
		tokenizer.source,
		tokens.Span{start = start, end = tokenizer.cursor},
		err_name,
		"unexpected character",
		should_panic = true,
	)

	return spanned(tokenizer, start, tokens.Eof{})
}

next_token :: proc(tokenizer: ^Tokenizer, allocator: runtime.Allocator) -> tokens.Spanned_Token {
	if tokenizer.has_peeked {
		tokenizer.has_peeked = false
		return tokenizer.peeked_token
	}
	return scan_token(tokenizer, allocator)
}

peek_token :: proc(tokenizer: ^Tokenizer, allocator: runtime.Allocator) -> tokens.Spanned_Token {
	if !tokenizer.has_peeked {
		tokenizer.peeked_token = scan_token(tokenizer, allocator)
		tokenizer.has_peeked = true
	}
	return tokenizer.peeked_token
}

skip_whitespace_and_comments :: proc(tokenizer: ^Tokenizer) -> bool {
	for !is_at_end(tokenizer) {
		c := peek(tokenizer)

		if unicode.is_white_space(c) {
			advance(tokenizer)
			continue
		}

		if c == '/' {
			next, ok := peek_next(tokenizer)
			if !ok do break

			if next == '/' {
				for !is_at_end(tokenizer) && peek(tokenizer) != '\n' {
					advance(tokenizer)
				}
				continue
			}

			if next == '*' {
				advance(tokenizer, 2)

				closed := false
				for !is_at_end(tokenizer) {
					curr := peek(tokenizer)
					nxt, nxt_ok := peek_next(tokenizer)

					if curr == '*' && nxt_ok && nxt == '/' {
						advance(tokenizer, 2)
						closed = true
						break
					}

					advance(tokenizer)
				}

				if !closed do return false
				continue
			}
		}
		break
	}
	return true
}
