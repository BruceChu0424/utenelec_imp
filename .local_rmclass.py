import io, sys
p = sys.argv[1]
lines = io.open(p, encoding='utf-8').read().split('\n')

def find_idx(pred, start=0):
    for i in range(start, len(lines)):
        if pred(lines[i]):
            return i
    raise SystemExit('MISS')

def cut_member(sig_pred, end_pred='  }'):
    i = find_idx(sig_pred)
    j = i + 1
    while lines[j].rstrip('\r') != end_pred:
        j += 1
    del lines[i:j+1]
    while i < len(lines) and lines[i].strip() == '' and lines[i-1].strip() == '':
        del lines[i]

cut_member(lambda l: l.strip().startswith('void _clearSelection('))
cut_member(lambda l: l.strip().startswith('void _toggleSelected('))
cut_member(lambda l: l.strip().startswith('void _selectCurrentPage('))
cut_member(lambda l: l.strip().startswith('String? get _emptyDescription') or l.strip().startswith('String? _emptyDescription'))

out = []
for l in lines:
    if l.strip() == '' and out and out[-1].strip() == '':
        continue
    out.append(l)
io.open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
print('ok')
