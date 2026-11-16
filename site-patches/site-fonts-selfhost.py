#!/usr/bin/env python3
"""Switch the redesigned AirlockRevival pages from Google Fonts to the fonts in ./fonts/.
Run from /var/www/token-gen AFTER nginx serves /fonts/. Verifies everything by SHA-256."""
import glob, hashlib, urllib.request

FONTS = {
    'inter-latin-wght-normal.woff2': '3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62',
    'space-grotesk-latin-wght-normal.woff2': '0640890476fc1198ab4de571fb658de443c4d85b66466ec09534a8737ab1ce9d',
}
HASHES = {'my': ('81bd60525c1bfd800e6bceeddc872b1f8343f827039f490532c5c253578ed324', '592fef4f9fc248c3b5b7b816f7f3b40de4872af8cc55d2724cc4b2546c48bbf9'), 'faq': ('bd1a60f5f0902d6082d509e0ec99d53bf6d18d2dd1757c1c87c90154b8cb7d13', '9e95563fbc857a80e5528591046288661d756f98b642ffec24678d4924e88fcc'), 'about': ('514c9b8e66d94e3407c4f1e7f31f99d147e8be0ade4f0eb5acbd46031e899eb1', 'ccc821cb9024ac888424fb75d8912d053dbdafcae218d551254032a393f35971'), 'get-token': ('6b04ed0086843f27a6d3c27a802794d65e034282d75da36a5615edb2a27a9be6', '90211cda213891e63d57c35b8ae5ae3a635a784d91b5af42b0b0e598714af652'), 'landing': ('94365c733de945fcc6a23c4e9dd188c5fcb71c17ce706d4ce8cf78485440772a', '4e6ddeb5280bb4a7f074b563f6164a912c1cafb1c886d3abe71d4b8e5941a063')}  # name -> (with Google Fonts, with self-hosted fonts)
GOOGLE = "@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap');"
SELF = "@font-face { font-family: 'Inter'; font-style: normal; font-weight: 100 900; font-display: swap; src: url('/fonts/inter-latin-wght-normal.woff2') format('woff2'); }\n  @font-face { font-family: 'Space Grotesk'; font-style: normal; font-weight: 300 700; font-display: swap; src: url('/fonts/space-grotesk-latin-wght-normal.woff2') format('woff2'); }"
MYFONT = '<link rel="preconnect" href="https://fonts.googleapis.com">\n<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap">\n<style>\n  :root {'

h = lambda t: hashlib.sha256(t.encode('utf-8')).hexdigest()
for name, want in FONTS.items():
    try:
        req = urllib.request.Request('https://airlock.craftlab.no/fonts/' + name, headers={'User-Agent': 'site-redesign-patch'})
        ok = hashlib.sha256(urllib.request.urlopen(req, timeout=30).read()).hexdigest() == want
    except Exception:
        ok = False
    if not ok:
        raise SystemExit('STOP: https://airlock.craftlab.no/fonts/' + name + ' is not served correctly yet. Nothing changed.')

files = {}
for path in glob.glob('*.html'):
    try:
        files[path] = open(path, encoding='utf-8', newline='').read()
    except UnicodeDecodeError:
        pass
todo = []
for name, (g, s_hash) in HASHES.items():
    if any(h(t) == s_hash for t in files.values()):
        print('skip  %-10s already switched' % name)
        continue
    src = [p for p, t in files.items() if h(t) == g]
    if len(src) != 1:
        raise SystemExit('STOP: cannot find the Google Fonts version of "%s". Nothing changed.' % name)
    s = files[src[0]]
    old, new = (MYFONT, '<style>\n  ' + SELF + '\n  :root {') if name == 'my' else (GOOGLE, SELF)
    if s.count(old) != 1:
        raise SystemExit('STOP: anchor mismatch in ' + name + '. Nothing changed.')
    s = s.replace(old, new)
    if h(s) != s_hash:
        raise SystemExit('STOP: result for "%s" does not match the tested version. Nothing changed.' % name)
    todo.append((name, src[0], s))
for name, path, s in todo:
    open(path, 'w', encoding='utf-8', newline='').write(s)
    print('ok    %-10s %s' % (name, path))
print('DONE: %d page(s) switched to self-hosted fonts' % len(todo))
