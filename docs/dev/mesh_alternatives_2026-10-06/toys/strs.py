import re,sys
for f in sys.argv[2:]:
    b=open(f,'rb').read()
    for m in re.finditer(rb'[\x20-\x7e]{6,}',b):
        s=m.group().decode()
        if re.search(sys.argv[1],s,re.I): print(f.split('/')[-1],':',s[:160])
