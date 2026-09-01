module main

import net
import net.ssl
import net.urllib
import time
import os

fn main() {
	mut port := 7777
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
	client.set_read_timeout(time.second * 30)

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
		cors_res := 'HTTP/1.1 200 OK\r\n' + 'Access-Control-Allow-Origin: *\r\n' + 'Access-Control-Allow-Methods: GET, POST, PUT, DELETE, PATCH, OPTIONS\r\n' + 'Access-Control-Allow-Headers: ${req_headers_val}\r\n' + 'Access-Control-Expose-Headers: *\r\n' + 'Content-Length: 2\r\n\r\nok'
		client.write_string(cors_res) or {}
		return
	}

	mut target_url_str := ''
	for line in lines {
		if line.to_lower().starts_with('x-target-url:') {
			parts := line.split(':')
			if parts.len > 1 {
				target_url_str = line[parts[0].len + 1..].trim_space()
			}
		}
	}

	if target_url_str == '' {
		client.write_string('HTTP/1.1 400 Bad Request\r\n\r\nMissing X-Target-Url header') or {}
		return
	}

	target_url := urllib.parse(target_url_str) or {
		client.write_string('HTTP/1.1 400 Bad Request\r\n\r\nInvalid target URL') or {}
		return
	}

	host := target_url.hostname()
	mut port := target_url.port().int()
	if port == 0 {
		port = if target_url.scheme == 'https' { 443 } else { 80 }
	}

	mut target_ptr := voidptr(0)

	if target_url.scheme == 'https' {
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
	mut raw_path := target_url_str.replace(target_url.scheme + '://' + host, '')
	if raw_path.starts_with(':' + port.str()) {
		raw_path = raw_path[port.str().len + 1..]
	}
	if raw_path == '' {
		raw_path = '/'
	}

	mut out_req := '${method} ${raw_path} HTTP/1.1\r\n'
	out_req += 'Host: ${host}\r\n'
	out_req += 'Connection: close\r\n'

	for line in lines[1..] {
		if line == '' {
			break
		}
		l_lower := line.to_lower()
		if l_lower.starts_with('host:') || l_lower.starts_with('connection:') || l_lower.starts_with('x-target-') {
			continue
		}
		out_req += line + '\r\n'
	}
	out_req += '\r\n'

	unsafe {
		if target_url.scheme == 'https' {
			mut t_ssl := &ssl.SSLConn(target_ptr)
			t_ssl.write_string(out_req) or {}
		} else {
			mut t_tcp := &net.TcpConn(target_ptr)
			t_tcp.write_string(out_req) or {}
		}
	}

	// Spawn chunk streaming for two-way pipe
	client_ptr := voidptr(&client)

	// Target -> Client chunk streaming (blocking in this thread)
	spawn pipe_stream_ct(client_ptr, target_ptr, target_url.scheme)
	unsafe {
		mut buf := []u8{len: 4096}
		mut headers_passed := false
		mut header_data := []u8{}

		if target_url.scheme == 'https' {
			mut t_ssl := &ssl.SSLConn(target_ptr)
			for {
				n := t_ssl.read(mut buf) or { break }
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

						mod_headers += '\r\nAccess-Control-Allow-Origin: *'
						mod_headers += '\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, PATCH, OPTIONS'
						mod_headers += '\r\nAccess-Control-Allow-Headers: *'
						mod_headers += '\r\nAccess-Control-Expose-Headers: *'
						mod_headers += '\r\n\r\n'

						client.write_string(mod_headers) or { break }

						body_part := header_data[end_idx + 4..]
						if body_part.len > 0 {
							client.write(body_part) or { break }
						}
						header_data = []u8{} // free memory
					}
				} else {
					client.write(buf[..n]) or { break }
				}
			}
			t_ssl.close() or {}
		} else {
			mut t_tcp := &net.TcpConn(target_ptr)
			for {
				n := t_tcp.read(mut buf) or { break }
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

						mod_headers += '\r\nAccess-Control-Allow-Origin: *'
						mod_headers += '\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, PATCH, OPTIONS'
						mod_headers += '\r\nAccess-Control-Allow-Headers: *'
						mod_headers += '\r\nAccess-Control-Expose-Headers: *'
						mod_headers += '\r\n\r\n'

						client.write_string(mod_headers) or { break }

						body_part := header_data[end_idx + 4..]
						if body_part.len > 0 {
							client.write(body_part) or { break }
						}
						header_data = []u8{} // free memory
					}
				} else {
					client.write(buf[..n]) or { break }
				}
			}
			t_tcp.close() or {}
		}
	}
}

// Client -> Target chunk streaming
fn pipe_stream_ct(client_ptr voidptr, target_ptr voidptr, scheme string) {
	unsafe {
		mut client := &net.TcpConn(client_ptr)
		mut buf := []u8{len: 4096}
		if scheme == 'https' {
			mut t_ssl := &ssl.SSLConn(target_ptr)
			for {
				n := client.read(mut buf) or { break }
				if n == 0 {
					break
				}
				t_ssl.write(buf[..n]) or { break }
			}
		} else {
			mut t_tcp := &net.TcpConn(target_ptr)
			for {
				n := client.read(mut buf) or { break }
				if n == 0 {
					break
				}
				t_tcp.write(buf[..n]) or { break }
			}
		}
	}
}
