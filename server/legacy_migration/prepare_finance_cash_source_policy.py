"""Package an explicitly reviewed historical cash-source classification; source only."""
from pathlib import Path
import argparse,json
from finance_cash_source_policy import prepare_package

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('reviewed-dispositions','source-semantics','typed-source-native','raw','inputs','output'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    result=prepare_package(args.reviewed_dispositions,args.source_semantics,args.typed_source_native,args.raw,args.inputs,args.output)
    print(json.dumps({'status':'EXACT_REVIEWED_CASH_SOURCE_POLICY_PREPARED','policy_sha256':result['policy_sha256'],
      'source_rows':{name:item['rows'] for name,item in result['inventory'].items()},
      'archived_rows':{name:len(item['archive_ids']) for name,item in result['inventory'].items()},'target_accessed':False}))

if __name__=='__main__':main()
