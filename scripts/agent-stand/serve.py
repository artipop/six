"""Serves the agent stand on 127.0.0.1 and appends every form the pages submit to submitted.jsonl,
which is what a run is checked against — not the agent's own account of what it did."""
import http.server, json, sys, os
LOG=os.path.join(os.path.dirname(__file__),'submitted.jsonl')
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        open(LOG,'a').write(body.decode()+"\n"); self.send_response(204); self.end_headers()
os.chdir(os.path.dirname(os.path.abspath(__file__)))
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1]) if len(sys.argv)>1 else 8765),H).serve_forever()
