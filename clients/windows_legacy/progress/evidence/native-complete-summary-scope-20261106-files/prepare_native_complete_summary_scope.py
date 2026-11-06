from pathlib import Path
import datetime, difflib, hashlib, json, os, subprocess, xml.etree.ElementTree as ET

ROOT = Path('D:/Projects/uten_imp')
OUT = ROOT / 'build/loading-validation/native-complete-summary-scope-20261106'
TREE = OUT / 'tree'
FIXTURE = ROOT / 'build/loading-validation/owning-summary-scope-closeout-v4/tree/contracts/read-scope-domains/complete-summary-v1.json'
LEAVES = [
 'clients/windows_legacy/Uten.Legacy.Core/ReadScopeRevisionState.cs',
 'clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs',
 'clients/windows_legacy/Uten.Legacy.Core/Tests/ReadScopeRevisionChecks.cs',
 'clients/windows_legacy/Uten.Legacy.Core/Uten.Legacy.Core.csproj',
]
def sha(data): return hashlib.sha256(data).hexdigest()
def write(rel, raw):
 p = TREE / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(raw)
def once(text, old, new):
 if text.count(old) != 1: raise RuntimeError('Expected one exact preimage: ' + old[:95])
 return text.replace(old, new, 1)

def main():
 OUT.mkdir(exist_ok=False)
 head = subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD']).decode().strip()
 idx = subprocess.check_output(['git','-C',str(ROOT),'rev-parse','--git-path','index']).decode().strip()
 index = Path(idx); index = index if index.is_absolute() else ROOT / index
 before = {n:(ROOT/n).read_bytes() for n in LEAVES}
 ns={'m':'http://schemas.microsoft.com/developer/msbuild/2003'}
 project = ET.fromstring(before[LEAVES[-1]])
 physical = set(LEAVES)
 for tag in ('Compile','EmbeddedResource'):
  for row in project.findall('.//m:'+tag,ns):
   physical.add(((ROOT/'clients/windows_legacy/Uten.Legacy.Core')/row.attrib['Include'].replace('\\','/')).resolve().relative_to(ROOT.resolve()).as_posix())
 physical.update(['clients/windows_legacy/BuildIsolation.props','clients/windows_legacy/BuildVersion.targets','pubspec.yaml'])
 inputs={}
 for rel in sorted(physical):
  raw=(ROOT/rel).read_bytes(); write(rel,raw); inputs[rel]=sha(raw)
 write('contracts/read-scope-domains/complete-summary-v1.json',FIXTURE.read_bytes())
 texts={n:raw.decode('utf-8').replace('\r\n','\n') for n,raw in before.items()}
 name=LEAVES[0]; text=texts[name]
 text=once(text,'internal readonly CancellationToken Cancellation;','internal readonly CancellationToken Cancellation;\n        internal readonly HttpMethod Method;')
 text=once(text,'internal ReadRequest(long revision, long sequence, CancellationToken cancellation)\n        { Revision = revision; Sequence = sequence; Cancellation = cancellation; }','internal ReadRequest(long revision, long sequence, CancellationToken cancellation, HttpMethod method = null)\n        { Revision = revision; Sequence = sequence; Cancellation = cancellation; Method = method ?? HttpMethod.Get; }')
 anchor='        private static readonly Dictionary<string, string> MasterDomains'
 text=once(text,anchor,'        private static readonly Regex FinanceSummaryPath = new Regex(\n            "^/(?:api/)?finance/(?:(?:asset-opening-groups|accounting-imports|auxiliary-imports)/summaries|chart/imports/summaries|expense-analysis/note-imports/summaries|payable-statement-adjustments|statement-documents/reviews/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/(?:summary|original-table))$",\n            RegexOptions.CultureInvariant);\n'+anchor)
 text=once(text,'var domain = native ?? DomainFromPath(path);','var domain = native ?? DomainFromPath(path, request.Method);')
 text=once(text,'private static string DomainFromPath(string path)','private static string DomainFromPath(string path, HttpMethod method)')
 text=once(text,'            if (SettlementPath.IsMatch(path)) return "master_settlement_method";','            if (SettlementPath.IsMatch(path)) return "master_settlement_method";\n            // Only the owning GET routes publish a finance version without a domain header.\n            // Native response domains take precedence above; other finance reads stay unclassified.\n            if (method.Equals(HttpMethod.Get) && FinanceSummaryPath.IsMatch(path)) return "finance";')
 texts[name]=text
 name=LEAVES[1]; texts[name]=once(texts[name],'new ReadRequest(readScopes.Revision, ++readSequence, readCancellation.Token);','new ReadRequest(readScopes.Revision, ++readSequence, readCancellation.Token, method);')
 name=LEAVES[3]
 resource='    <EmbeddedResource Include="..\\..\\..\\contracts\\read-scope-domains\\complete-summary-v1.json" Condition=" \'$(Configuration)\' == \'Debug\' ">\n      <LogicalName>Uten.Legacy.Core.CompleteSummaryReadScopeFixture.json</LogicalName>\n    </EmbeddedResource>\n'
 texts[name]=once(texts[name],'    <Compile Include="ManagedCertificateValidator.cs" />',resource+'    <Compile Include="ManagedCertificateValidator.cs" />')
 name=LEAVES[2]
 texts[name]=once(texts[name],'            GoodsCostDomainsAreIndependent().GetAwaiter().GetResult();','            GoodsCostDomainsAreIndependent().GetAwaiter().GetResult();\n            CompleteSummaryMethodsAndExactRoutes();\n            CompleteSummaryDomainsAreIndependent().GetAwaiter().GetResult();')
 methods=r'''
        private static Dictionary<string, object> CompleteSummaryContract()
        {
            using (var stream = typeof(SessionCoordinator).Assembly.GetManifestResourceStream("Uten.Legacy.Core.CompleteSummaryReadScopeFixture.json"))
            using (var reader = new StreamReader(stream, Encoding.UTF8))
            {
                var contract = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                Equal(1, Convert.ToInt32(contract["schemaVersion"]), "shared complete summary scope contract version");
                return contract;
            }
        }

        private static void CompleteSummaryMethodsAndExactRoutes()
        {
            var contract = CompleteSummaryContract();
            var cases = ((IEnumerable)contract["cases"]).Cast<Dictionary<string, object>>().ToArray();
            foreach (var item in cases)
            {
                var state = new ReadScopeRevisionState();
                var method = new HttpMethod((string)item["method"]);
                var headers = new ReadScopeHeaders { Version = "owning-first", Domain = (string)item["headerDomain"] };
                var original = ReadScopeProof.Read("{\"items\":[],\"total\":0}", headers);
                Equal(ReadProofDisposition.Accepted, state.Observe(new ReadRequest(0, 1, CancellationToken.None, method), "/api" + (string)item["path"], original),
                    "first exact route/method establishes its owning proof");
                headers = new ReadScopeHeaders { Version = "owning-changed", Domain = (string)item["headerDomain"] };
                Equal(ReadProofDisposition.Retired, state.Observe(new ReadRequest(0, 2, CancellationToken.None, method), (string)item["path"],
                    ReadScopeProof.Read("{\"items\":[],\"total\":0}", headers)), "each shared fixture route observes a changed header-only owning proof");
                Equal(1L, state.Revision, "api and bare route aliases share the owning proof");
            }
            var negatives = ((IEnumerable)contract["unclassified"]).Cast<Dictionary<string, object>>().ToArray();
            foreach (var item in negatives)
            {
                var state = new ReadScopeRevisionState();
                var method = new HttpMethod((string)item["method"]);
                for (var index = 0; index < 2; index++)
                    Equal(ReadProofDisposition.Accepted, state.Observe(new ReadRequest(0, index + 1, CancellationToken.None, method), "/api" + (string)item["path"],
                        ReadScopeProof.Read("{\"items\":[]}", new ReadScopeHeaders { Version = "unclassified-" + index })),
                        "neighboring route or wrong method must not create a fallback finance authority");
                Equal(0L, state.Revision, "unclassified route proofs cannot retire unrelated readers");
            }
        }

        private static async Task CompleteSummaryDomainsAreIndependent()
        {
            var cases = ((IEnumerable)CompleteSummaryContract()["cases"]).Cast<Dictionary<string, object>>()
                .Where(item => (string)item["method"] == "GET").ToArray();
            var byPath = cases.ToDictionary(item => "/api" + (string)item["path"]);
            var proofs = cases.Select(item => (string)item["domain"]).Distinct()
                .ToDictionary(domain => domain, domain => "separate-authority-" + domain);
            var requests = 0;
            const string headerOnlyBody = " { \"items\" : [], \"total\" : 0 } \n";
            using (var fixture = new Fixture((request, token) =>
            {
                requests++;
                var item = byPath[request.RequestUri.AbsolutePath];
                var version = proofs[(string)item["domain"]];
                // Finance's real producer publishes only the version header; it has no body proof.
                return Ready(Proof(headerOnlyBody, version, (string)item["headerDomain"]));
            }))
            {
                await fixture.Login();
                var revision = fixture.Session.ReadScopeRevision;
                var generation = fixture.Session.Generation;
                var refresh = fixture.Store.Load().RefreshToken;
                var events = 0;
                fixture.Session.ReadScopeChanged += (sender, args) => events++;
                for (var round = 0; round < 25; round++)
                    foreach (var item in cases)
                        Equal(headerOnlyBody, await fixture.Session.GetAsync(((string)item["path"]).TrimStart('/'), CancellationToken.None),
                            "real SessionCoordinator preserves original response and the published owning header");
                Equal(cases.Length * 25, requests, "all fixture GET callers traversed the actual HTTP/session/proof chain");
                Equal(revision, fixture.Session.ReadScopeRevision, "different finance/native proofs never replace another authority");
                var changed = 0;
                foreach (var domain in proofs.Keys.ToArray())
                {
                    proofs[domain] += "-changed";
                    var selected = cases.First(item => (string)item["domain"] == domain);
                    await Changed(() => fixture.Session.GetAsync(((string)selected["path"]).TrimStart('/'), CancellationToken.None));
                    changed++;
                    foreach (var item in cases)
                        await fixture.Session.GetAsync(((string)item["path"]).TrimStart('/'), CancellationToken.None);
                    Equal(revision + changed, fixture.Session.ReadScopeRevision, "all owning aliases adopt one real authority change without cross-domain retirement");
                }
                Equal(proofs.Count, events, "one retirement per changed owning authority");
                Equal(generation, fixture.Session.Generation, "owning proof changes retain authentication generation");
                Equal(refresh, fixture.Store.Load().RefreshToken, "owning proof changes retain persisted login");
                NoAutomaticAuthenticationOrWrite(fixture);
            }
        }
'''
 texts[name]=once(texts[name],'        private static async Task IdentityChangesForgetProofsAndRejectOldResponses()',methods+'\n        private static async Task IdentityChangesForgetProofsAndRejectOldResponses()')
 changes=[]
 for name in LEAVES:
  rendered=texts[name].replace('\n','\r\n') if b'\r\n' in before[name] else texts[name]
  raw=rendered.encode('utf-8'); write(name,raw)
  prior=OUT/'before'/name; prior.parent.mkdir(parents=True,exist_ok=True);prior.write_bytes(before[name])
  patch=OUT/'patches'/(name+'.patch');patch.parent.mkdir(parents=True,exist_ok=True)
  patch.write_text(''.join(difflib.unified_diff(before[name].decode('utf-8').splitlines(),rendered.splitlines(),fromfile=name,tofile=name,lineterm='\n')),'utf-8')
  changes.append({'path':name,'beforeSha256':sha(before[name]),'proposedSha256':sha(raw)})
 fixture = json.loads(FIXTURE.read_bytes())
 receipt={'atUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'mainHeadAtProposal':head,'mainIndexSha256AtProposal':sha(index.read_bytes()),'changes':changes,'fixturePath':'contracts/read-scope-domains/complete-summary-v1.json','fixtureSource':str(FIXTURE),'fixtureSha256':sha(FIXTURE.read_bytes()),'fixturePositiveRows':len(fixture['cases']),'fixtureNegativeRows':len(fixture['unclassified']),'privateInputMap':inputs,'MainWritten':False,'validationExecuted':False,'nativeBusinessUiAdded':False,'fullErpOrWin7Accepted':False}
 (OUT/'review.json').write_text(json.dumps(receipt,indent=2)+'\n','utf-8')
 print(json.dumps({'out':str(OUT),'changes':len(changes),'privateInputs':len(inputs),'fixture':receipt['fixtureSha256']}))

if __name__=='__main__':main()
