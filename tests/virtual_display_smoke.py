"""Create and remove only a temporary display owned by this app session."""
import json
import time
from server_smoke import CONFIG, request


def main():
    code, headers, _ = request('POST', '/api/login', {'token':CONFIG['token']})
    assert code == 200
    cookie = {'Cookie':headers['Set-Cookie'].split(';')[0]}
    code, _, body = request('GET','/api/status',headers=cookie)
    state = json.loads(body)
    assert code == 200 and state['screenPermission'], 'Screen recording permission is required'
    assert not state['virtualDisplay'], 'An existing user virtual display must be preserved; remove it manually before this test'
    assert state['displays'] and not state['monitorsOff'], 'A replacement display must already be available'
    created = 0
    try:
        code, _, body = request('POST','/api/virtual',{},cookie)
        state = json.loads(body)
        assert code == 200, state
        created = state['virtualDisplay']
        assert created and state['selectedDisplay'] == created
        code, _, body = request('POST','/api/virtual/remove',{},cookie)
        state = json.loads(body)
        assert code == 200, state
        assert state['virtualDisplay'] == 0
        assert state['selectedDisplay'] != created and state['selectedDisplay'] != 0
        assert all(display['id'] != created for display in state['displays'])
        code, _, body = request('POST','/api/virtual/remove',{},cookie)
        assert code == 200, body
        code, _, body = request('GET','/api/frame',headers=cookie)
        assert code == 200 and body.startswith(b'\xff\xd8'), 'Replacement desktop image is missing'
        print('Temporary virtual display removed; capture continues on the replacement screen.')
    finally:
        if created:
            _, _, body = request('GET','/api/status',headers=cookie)
            if json.loads(body)['virtualDisplay'] == created:
                code, _, body = request('POST','/api/virtual/remove',{},cookie)
                assert code == 200, 'Temporary virtual display cleanup failed: ' + body.decode()


if __name__ == '__main__':
    main()
