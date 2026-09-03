module main

import net
import net.ssl
import os

const build_port = $env('PROXY_PORT')
const build_origin = $env('PROXY_ORIGIN')
const build_header = $env('PROXY_HEADER')

fn main() {
	mut port := 7777
	if build_port != '' {
		port = build_port.int()
	}
	
	if os.args.len > 1 {
		parsed_port := os.args[1].int()
		if parsed_port > 0 && parsed_port <= 65535 {
			port = parsed_port
		} else {
			println('⚠️  Invalid port number "${os.args[1]}". Falling back to default.')
		}
	}

	mut listener := net.listen_tcp(.ip, ':${port}') or {
		println('Failed to start server: ${err}')
		return
	}
	println('Streaming API Proxy (Raw TCP Chunked) is running on http://localhost:${port}')
	println('To use a custom port, run: ./proxy_stream <port_number>')

	for {
		mut client := listener.accept() or {
			println('Accept error: ${err}')
			continue
		}
		spawn handle_client(mut client)
	}
}

fn handle_client(mut client net.TcpConn) {
	defer { client.close() or {} }
	client.set_read_timeout(30000000000) // 30 seconds in nanoseconds

	mut header_buf := []u8{cap: 4096}
	mut temp_buf := []u8{len: 1}

	mut matched_end := 0
	for {
		n := client.read(mut temp_buf) or { break }
		if n == 0 {
			break
		}

		b := temp_buf[0]
		header_buf << b

		if b == `\r` && matched_end == 0 {
			matched_end = 1
		} else if b == `\n` && matched_end == 1 {
			matched_end = 2
		} else if b == `\r` && matched_end == 2 {
			matched_end = 3
		} else if b == `\n` && matched_end == 3 {
			matched_end = 4
			break
		} else {
			matched_end = 0
		}
	}

	if matched_end != 4 {
		return // Invalid HTTP request
	}

	header_str := header_buf.bytestr()
	lines := header_str.split('\r\n')
	if lines.len == 0 {
		return
	}

	req_line := lines[0].split(' ')
	if req_line.len < 3 {
		return
	}
	method := req_line[0]
	req_path := req_line[1]

	mut origin := ''
	for line in lines {
		if line.to_lower().starts_with('origin:') {
			parts := line.split(':')
			if parts.len > 1 {
				origin = line[parts[0].len + 1..].trim_space()
			}
		}
	}
	
	mut is_allowed := true
	if build_origin != '' {
		is_allowed = false
		if origin == '' || origin == build_origin || origin == '${build_origin}/' || origin.starts_with('http://localhost:') {
			is_allowed = true
		}
	}
	
	if !is_allowed {
		client.write_string('HTTP/1.1 403 Forbidden\r\n\r\nUnauthorized Origin: ${origin}') or {}
		return
	}

	// Handle preflight
	if method == 'OPTIONS' {
		mut req_headers_val := '*'
		for line in lines {
			if line.to_lower().starts_with('access-control-request-headers:') {
				parts := line.split(':')
				if parts.len > 1 {
					req_headers_val = line[parts[0].len + 1..].trim_space()
				}
			}
		}
		mut allow_origin := '*'
		if build_origin != '' {
			allow_origin = if origin != '' { origin } else { '*' }
		}
		cors_res := 'HTTP/1.1 200 OK\r\n' + 'Access-Control-Allow-Origin: ${allow_origin}\r\n' + 'Access-Control-Allow-Methods: GET, POST, PUT, DELETE, PATCH, OPTIONS\r\n' + 'Access-Control-Allow-Headers: ${req_headers_val}\r\n' + 'Access-Control-Expose-Headers: *\r\n' + 'Content-Length: 2\r\n\r\nok'
		client.write_string(cors_res) or {}
		return
	}

	mut target_header := 'x-target-url'
	if build_header != '' {
		target_header = build_header.to_lower()
	}

	mut target_url_str := ''
	
	// 1. Try to get target from query parameter ?url=
	url_idx := req_path.index('?url=') or { -1 }
	if url_idx != -1 {
		raw_query_url := req_path[url_idx + 5..]
		target_url_str = unescape_url(raw_query_url)
	}

	// 2. Fallback to header
	if target_url_str == '' {
		for line in lines {
			if line.to_lower().starts_with('${target_header}:') {
				parts := line.split(':')
				if parts.len > 1 {
					target_url_str = line[parts[0].len + 1..].trim_space()
				}
			}
		}
	}

	if target_url_str == '' {
		client.write_string('HTTP/1.1 400 Bad Request\r\n\r\nMissing ${target_header} header or ?url= parameter') or {}
		return
	}

	mut scheme := 'http'
	mut rest := target_url_str
	if rest.starts_with('https://') {
		scheme = 'https'
		rest = rest[8..]
	} else if rest.starts_with('http://') {
		scheme = 'http'
		rest = rest[7..]
	}

	slash_idx := rest.index('/') or { rest.len }
	host_port := unsafe { rest[..slash_idx] }

	mut host := host_port
	mut port := if scheme == 'https' { 443 } else { 80 }

	colon_idx := host_port.index(':') or { -1 }
	if colon_idx != -1 {
		host = unsafe { host_port[..colon_idx] }
		port = host_port[colon_idx + 1..].int()
	}

	mut target_ptr := voidptr(0)

	if scheme == 'https' {
		mut target_ssl := ssl.new_ssl_conn(verify: '') or {
			client.write_string('HTTP/1.1 502 Bad Gateway\r\n\r\nFailed to init SSL') or {}
			return
		}
		target_ssl.dial(host, port) or {
			client.write_string('HTTP/1.1 502 Bad Gateway\r\n\r\nFailed to connect HTTPS') or {}
			return
		}
		target_ptr = voidptr(target_ssl)
	} else {
		mut target_tcp := net.dial_tcp('${host}:${port}') or {
			client.write_string('HTTP/1.1 502 Bad Gateway\r\n\r\nFailed to connect HTTP') or {}
			return
		}
		target_ptr = voidptr(target_tcp)
	}

	// Reconstruct request path to forward
	mut raw_path := if slash_idx < rest.len { rest[slash_idx..] } else { '/' }

	mut out_req := '${method} ${raw_path} HTTP/1.1\r\n'
	out_req += 'Host: ${host}\r\n'
	out_req += 'Connection: close\r\n'

	for line in lines[1..] {
		if line == '' {
			break
		}
		l_lower := line.to_lower()
		if l_lower.starts_with('host:') || l_lower.starts_with('connection:') || l_lower.starts_with('${target_header}:') {
			continue
		}
		out_req += line + '\r\n'
	}
	out_req += '\r\n'

	client_ptr := voidptr(&client)

	if scheme == 'https' {
		unsafe {
			mut t_ssl := &ssl.SSLConn(target_ptr)
			t_ssl.write_string(out_req) or {}
			spawn pipe_stream_ct[ssl.SSLConn](client_ptr, target_ptr)
			handle_target_stream[ssl.SSLConn](mut client, mut t_ssl, origin, target_header)
		}
	} else {
		unsafe {
			mut t_tcp := &net.TcpConn(target_ptr)
			t_tcp.write_string(out_req) or {}
			spawn pipe_stream_ct[net.TcpConn](client_ptr, target_ptr)
			handle_target_stream[net.TcpConn](mut client, mut t_tcp, origin, target_header)
		}
	}
}

fn handle_target_stream[T](mut client net.TcpConn, mut target T, origin string, target_header string) {
	mut buf := []u8{len: 4096}
	mut headers_passed := false
	mut header_data := []u8{}

	for {
		n := target.read(mut buf) or { break }
		if n == 0 {
			break
		}
		if !headers_passed {
			header_data << buf[..n]
			mut end_idx := -1
			for i in 0 .. header_data.len - 3 {
				if header_data[i] == `\r` && header_data[i + 1] == `\n` && header_data[i + 2] == `\r` && header_data[i + 3] == `\n` {
					end_idx = i
					break
				}
			}
			if end_idx != -1 {
				headers_passed = true
				mut original_headers := header_data[0..end_idx].bytestr()

				mut clean_headers := ''
				for l in original_headers.split('\r\n') {
					if l.to_lower().starts_with('access-control-') {
						continue
					}
					clean_headers += l + '\r\n'
				}
				mut mod_headers := clean_headers.trim_right('\r\n')

				mut allow_origin := '*'
				if build_origin != '' {
					allow_origin = if origin != '' { origin } else { '*' }
				}
				mod_headers += '\r\nAccess-Control-Allow-Origin: ${allow_origin}'
				mod_headers += '\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, PATCH, OPTIONS'
				mod_headers += '\r\nAccess-Control-Allow-Headers: *'
				mod_headers += '\r\nAccess-Control-Expose-Headers: *'
				mod_headers += '\r\nVary: ${target_header}, Origin'
				mod_headers += '\r\n\r\n'

				client.write_string(mod_headers) or { break }

				body_part := unsafe { header_data[end_idx + 4..] }
				if body_part.len > 0 {
					client.write(body_part) or { break }
				}
				header_data = []u8{} // free memory
			}
		} else {
			client.write(buf[..n]) or { break }
		}
	}
	target.close() or {}
}

// Client -> Target chunk streaming
fn pipe_stream_ct[T](client_ptr voidptr, target_ptr voidptr) {
	unsafe {
		mut client := &net.TcpConn(client_ptr)
		mut target := &T(target_ptr)
		mut buf := []u8{len: 4096}
		for {
			n := client.read(mut buf) or { break }
			if n == 0 {
				break
			}
			// Use write_string + bytestr() instead of write() to bypass
			// a missing mbedtls C implementation bug on Windows MSVC.
			// V strings are binary-safe (can contain null bytes).
			target.write_string(buf[..n].bytestr()) or { break }
		}
	}
}

fn hex2int(c u8) u8 {
	if c >= `0` && c <= `9` { return c - `0` }
	if c >= `a` && c <= `f` { return c - `a` + 10 }
	if c >= `A` && c <= `F` { return c - `A` + 10 }
	return 0
}

fn unescape_url(s string) string {
	mut buf := []u8{cap: s.len}
	for i := 0; i < s.len; i++ {
		if s[i] == `%` && i + 2 < s.len {
			buf << (hex2int(s[i + 1]) << 4) | hex2int(s[i + 2])
			i += 2
		} else {
			buf << s[i]
		}
	}
	return buf.bytestr()
}