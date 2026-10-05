#!/usr/bin/env python3
"""Private endpoint provisioning. Credentials arrive on hidden stdin, never argv/logs.
Writes 0600 one-time device configuration; these are not source-controlled files.
"""
import sys, json, urllib.request, pathlib, os, datetime, uuid
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None
print('Ready for provisioning JSON on stdin (input is hidden).',flush=True)
import termios
attrs=termios.tcgetattr(sys.stdin); quiet=termios.tcgetattr(sys.stdin); quiet[3]&=~termios.ECHO; termios.tcsetattr(sys.stdin,termios.TCSANOW,quiet)
try: settings=json.loads(sys.stdin.readline())
finally: termios.tcsetattr(sys.stdin,termios.TCSANOW,attrs)
base=settings['siteURL'].rstrip('/'); platform=settings['platformToken']; root=pathlib.Path(settings['outputDirectory'])
root.mkdir(parents=True,exist_ok=True);os.chmod(root,0o700)
opener=urllib.request.build_opener(NoRedirect())
def post(path,body,device=None):
    headers={'Content-Type':'application/json','OAI-Sites-Authorization':'Bearer '+platform}
    if device: headers['Authorization']='Bearer '+device
    request=urllib.request.Request(base+path,data=json.dumps(body).encode(),headers=headers,method='POST')
    try:
        with opener.open(request,timeout=25) as response: return json.load(response)
    except Exception as e:
        # Do not dump request headers, response payload, or stdin credentials.
        raise RuntimeError('Private request failed: '+str(getattr(e,'code',type(e).__name__))) from None
results={}
for device in settings['devices']:
    file=root/(device['id']+'.json')
    if file.exists():
        config=json.loads(file.read_text()); assert config['siteURL']==base
    else:
        d=post('/api/devices/register',device)
        config={'siteURL':base,'platformToken':platform,'deviceToken':d['token'],'deviceId':d['id']}
        fd=os.open(file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as out: json.dump(config,out)
    results[device['id']]={'configurationFile':str(file),'registered':True}
    if device.get('probe'):
        now=datetime.datetime.now(datetime.timezone.utc)
        # Synthetic transport marker only; never interpreted as a human activity.
        observation={'schemaVersion':1,'eventId':str(uuid.uuid4()),'sequence':1,'source':'bridge.probe','observedAt':now.isoformat(),'expiresAt':(now+datetime.timedelta(seconds=60)).isoformat(),'assertion':'observed','value':{'synthetic':True,'state':'transport-probe'}}
        receipt=post('/api/ingest',{'observations':[observation]},config['deviceToken'])
        flush=post('/api/flush',{},config['deviceToken'])
        results[device['id']].update({'accepted':len(receipt.get('accepted',[])),'batchCreated':bool(flush.get('batchId')),'activeSubscriptions':flush.get('activeSubscriptions')})
print(json.dumps(results,ensure_ascii=False))
