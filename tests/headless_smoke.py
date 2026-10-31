import json
from pathlib import Path
import subprocess
import time
from server_smoke import request, CONFIG

ROOT = Path(__file__).resolve().parents[1]
PROBE = Path.home() / 'Library/Caches/MacWebRemote-build/DisplayInventory'

def inventory():
    return json.loads(subprocess.check_output([str(PROBE)], text=True))

_, headers, _ = request('POST', '/api/login', {'token':CONFIG['token']})
HEADERS = {'Cookie':headers['Set-Cookie'].split(';')[0]}

def api(path, payload=None):
    code, _, body = request('GET' if payload is None else 'POST','/api/'+path,payload,HEADERS)
    value=json.loads(body)
    if code != 200:
        raise RuntimeError(f'{path}: {code}: {value}')
    return value

report = {'before': inventory()}
report['physicalIDs'] = [d['id'] for d in report['before']['displays']]
try:
    virtual = api('virtual', {})
    for _ in range(40):
        virtual = api('status')
        if virtual['selectedDisplay'] == virtual['virtualDisplay'] and virtual['frames'] > 0:
            break
        time.sleep(.2)
    assert virtual['virtualDisplay'] != 0 and virtual['frames'] > 0
    report['virtualBeforeOff'] = virtual
    report['offResponse'] = api('monitors', {'off':True})
    time.sleep(1)
    report['whileOff'] = inventory()
    online = [d['id'] for d in report['whileOff']['displays']]
    assert online == [virtual['virtualDisplay']], online
    before_frames = api('status')['frames']
    for x,y in [(.25,.3),(.4,.4),(.6,.5)]:
        api('input', {'type':'move','x':x,'y':y})
        time.sleep(.3)
    report['afterMouse'] = inventory()
    report['captureWhileOff'] = api('status')
    assert report['captureWhileOff']['frames'] > before_frames
    cursor = report['afterMouse']['cursor']
    bounds = report['afterMouse']['displays'][0]
    assert abs(cursor['x'] - (bounds['x']+.6*(bounds['width']-1))) < 3, cursor
    assert abs(cursor['y'] - (bounds['y']+.5*(bounds['height']-1))) < 3, cursor
    code, _, frame = request('GET','/api/frame',headers=HEADERS)
    assert code == 200 and frame[:2] == b'\xff\xd8'
    (ROOT/'research/evidence/virtual-monitors-off.jpg').write_bytes(frame)
    report['jpegBytesWhileOff'] = len(frame)
    report['passed'] = True
finally:
    report['restoration'] = api('monitors', {'off':False})
    time.sleep(1)
    report['afterRestore'] = inventory()
    (ROOT/'research/evidence/headless-validation.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
print(json.dumps(report,indent=2,ensure_ascii=False))
