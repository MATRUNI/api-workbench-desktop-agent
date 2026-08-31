module main

import veb
import json2
import net.http
import encoding.base64

pub struct Context {
	veb.Context
}

pub struct App {}

pub fn (mut ctx Context) before_request() {
	ctx.res.header.add_custom('Access-Control-Allow-Origin', '*') or {}
	ctx.res.header.add_custom('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, PATCH, OPTIONS') or {}
	ctx.res.header.add_custom('Access-Control-Expose-Headers', 'X-Proxy-Headers-Base64') or {}
	ctx.res.header.add_custom('Access-Control-Allow-Headers', '*') or {}
}

fn main() {
	mut app := &App{}
	println('API Proxy Agent is running on http://localhost:7777')
	veb.run[App, Context](mut app, 7777)
}

@['/makeapicall'; options]
pub fn (app &App) preflight(mut ctx Context) veb.Result {
	return ctx.text('ok')
}

@['/makeapicall'; post]
pub fn (app &App) makeapicall(mut ctx Context) veb.Result {
	target_url := ctx.req.header.get_custom('X-Target-Url') or {
		ctx.res.status_code = 400
		return ctx.text('Missing X-Target-Url header in request')
	}
	target_method_str := ctx.req.header.get_custom('X-Target-Method') or { 'GET' }
	target_headers_json := ctx.req.header.get_custom('X-Target-Headers') or { '{}' }

	mut http_method := http.Method.get
	match target_method_str.to_upper() {
		'POST' {
			http_method = .post
		}
		'PUT' {
			http_method = .put
		}
		'DELETE' {
			http_method = .delete
		}
		'PATCH' {
			http_method = .patch
		}
		'OPTIONS' {
			http_method = .options
		}
		'HEAD' {
			http_method = .head
		}
		else {
			http_method = .get
		}
	}

	mut target_headers := http.new_header()

	target_headers_map := json2.decode[map[string]string](target_headers_json) or {
		map[string]string{}
	}
	for k, v in target_headers_map {
		target_headers.add_custom(k, v) or {}
	}

	req_content_type := ctx.req.header.get_custom('Content-Type') or { '' }
	if req_content_type != '' {
		target_headers.add_custom('Content-Type', req_content_type) or {}
	} else {
		if ctx.req.header.str().contains('Content-Type:') {
			lines := ctx.req.header.str().split('\n')
			for line in lines {
				if line.starts_with('Content-Type:') {
					val := line.replace('Content-Type:', '').trim_space()
					target_headers.add_custom('Content-Type', val) or {}
				}
			}
		}
	}

	resp := http.fetch(
		url: target_url
		method: http_method
		header: target_headers
		data: ctx.req.data
	) or {
		ctx.res.status_code = 502
		return ctx.text('Bad Gateway: Something went wrong with the HTTP proxy request: ${err}')
	}

	ctx.res.status_code = resp.status_code

	resp_content_type := resp.header.get_custom('Content-Type') or { '' }
	if resp_content_type != '' {
		ctx.res.header.add_custom('Content-Type', resp_content_type) or {}
	} else {
		if resp.header.str().contains('Content-Type:') {
			lines := resp.header.str().split('\n')
			for line in lines {
				if line.starts_with('Content-Type:') {
					val := line.replace('Content-Type:', '').trim_space()
					ctx.res.header.add_custom('Content-Type', val) or {}
				}
			}
		}
	}

	encoded_headers := base64.encode_str(resp.header.str())
	ctx.res.header.add_custom('X-Proxy-Headers-Base64', encoded_headers) or {}

	return ctx.ok(resp.body)
}
