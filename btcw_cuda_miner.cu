// BTCW CUDA miner for BitcoinPoW Core 31.x.
// From block 144444 the node re-signs with CKey::Sign(grind=false, uint32_t test_case)
// and accepts SHA256d(DER) at or below the live Stage-2 signature target.
#include <cuda_runtime.h>
#include <iostream>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <ctime>
#include <thread>
#include <atomic>
#include <vector>
#include <cstdlib>
#include <string>
#include <fstream>
#ifndef _WIN32
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif
#include <cerrno>
#include <csignal>

#include "btcw_cuda_kernels.cuh"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

static std::atomic<bool> g_running{true};
static void signal_handler(int){ g_running.store(false); }
static void print_timestamp(){ time_t now=time(nullptr); tm* lt=localtime(&now); char b[16]; strftime(b,sizeof(b),"%H:%M:%S",lt); printf("[%s] ",b); }
#define CUDA_CHECK(call) do { cudaError_t e=(call); if(e!=cudaSuccess){ fprintf(stderr,"CUDA error %s at %s:%d\n",cudaGetErrorString(e),__FILE__,__LINE__); return 1; } } while(0)
#ifdef _WIN32
#define SHM_NAME "shared_mem"
#else
#define SHM_NAME "/shared_mem"
#endif
static const int CTX_SIZE_BYTES=8*20, KEY_SIZE_BYTES=32, HASH_NO_SIG_SIZE_BYTES=32;
// Keep the original node IPC contract unchanged: key[32] + ctx[160] + hash_no_sig[32].
static const int TOTAL_BYTES_SEND=CTX_SIZE_BYTES+KEY_SIZE_BYTES+HASH_NO_SIG_SIZE_BYTES;
static const uint64_t SENTINEL_NONCE=0x0707070707070707ULL;
struct SharedData { volatile uint64_t nonce; volatile uint8_t data[TOTAL_BYTES_SEND]; };

static int hex_nibble(char c){
    if(c>='0'&&c<='9') return c-'0';
    if(c>='a'&&c<='f') return c-'a'+10;
    if(c>='A'&&c<='F') return c-'A'+10;
    return -1;
}

// hex is Bitcoin display order (MSB first). out[0] is LSB, matching
// uint256 / UintToArith256 / hash_meets_target_le.
static bool parse_target_hex(const char* hex, uint8_t out[32]){
    if(!hex) return false;
    if(hex[0]=='0'&&(hex[1]=='x'||hex[1]=='X')) hex+=2;
    size_t n=0; while(hex[n]&&hex[n]!='\r'&&hex[n]!='\n'&&hex[n]!=' '&&hex[n]!='"') ++n;
    if(n!=64) return false;
    for(int i=0;i<32;i++){
        int hi=hex_nibble(hex[2*i]), lo=hex_nibble(hex[2*i+1]);
        if(hi<0||lo<0) return false;
        out[31-i]=(uint8_t)((hi<<4)|lo);
    }
    return true;
}

static void target_to_hex(const uint8_t in[32], char out[65]){
    static const char* H="0123456789abcdef";
    for(int i=0;i<32;i++){ uint8_t b=in[31-i]; out[2*i]=H[b>>4]; out[2*i+1]=H[b&0xf]; }
    out[64]=0;
}

static bool load_target_file(const char* path, uint8_t out[32]){
    if(!path||!path[0]) return false;
    std::ifstream f(path);
    if(!f) return false;
    std::string line; if(!std::getline(f,line)) return false;
    return parse_target_hex(line.c_str(), out);
}

static bool extract_signaturetarget(const std::string& json, uint8_t out[32]){
    // Prefer the next-block target when present, else the tip field.
    size_t pos=std::string::npos;
    const size_t next=json.find("\"next\"");
    if(next!=std::string::npos) pos=json.find("\"signaturetarget\"", next);
    if(pos==std::string::npos) pos=json.find("\"signaturetarget\"");
    if(pos==std::string::npos) return false;
    pos=json.find(':', pos);
    if(pos==std::string::npos) return false;
    pos=json.find('"', pos+1);
    if(pos==std::string::npos||pos+1>=json.size()) return false;
    return parse_target_hex(json.c_str()+pos+1, out);
}

// Quote a path for the local shell. Returns empty if the value is not safe to interpolate.
static std::string shell_quote(const char* text){
    if(!text||!text[0]) return {};
    std::string out;
#ifdef _WIN32
    out.push_back('"');
#else
    out.push_back('\'');
#endif
    for(const char* p=text; *p; ++p){
#ifdef _WIN32
        if(*p=='"'||*p=='%'||*p=='\n'||*p=='\r') return {};
#else
        if(*p=='\''||*p=='\n'||*p=='\r') return {};
#endif
        out.push_back(*p);
    }
#ifdef _WIN32
    out.push_back('"');
#else
    out.push_back('\'');
#endif
    return out;
}

static bool fetch_target_rpc(uint8_t out[32]){
    const char* cli=std::getenv("BTCW_CLI");
    const char* datadir=std::getenv("BTCW_DATADIR");
    if(!cli||!cli[0]) cli="bitcoin-cli";
    const std::string qcli=shell_quote(cli);
    if(qcli.empty()) return false;
    std::string cmd=qcli+" -rpcclienttimeout=3";
    if(datadir&&datadir[0]){
        const std::string qdir=shell_quote(datadir);
        if(qdir.empty()) return false;
        cmd+=" -datadir="+qdir;
    }
    cmd+=" getmininginfo";
#ifdef _WIN32
    FILE* pipe=_popen(cmd.c_str(),"r");
#else
    FILE* pipe=popen(cmd.c_str(),"r");
#endif
    if(!pipe) return false;
    std::string json; char buf[512];
    while(fgets(buf,sizeof(buf),pipe)) json+=buf;
#ifdef _WIN32
    _pclose(pipe);
#else
    pclose(pipe);
#endif
    return extract_signaturetarget(json, out);
}

static bool load_signature_target(int argc,char** argv, uint8_t out[32], const char** src){
    if(argc>=5 && parse_target_hex(argv[4], out)){ *src="cli"; return true; }
    const char* env=std::getenv("BTCW_SIG_TARGET");
    if(env && parse_target_hex(env, out)){ *src="env"; return true; }
    if(fetch_target_rpc(out)){ *src="rpc"; return true; }
    const char* tf=std::getenv("BTCW_TARGET_FILE");
    if(!tf||!tf[0]) tf="target.txt";
    if(load_target_file(tf, out)){ *src="file"; return true; }
    return false;
}

int main(int argc,char** argv){
 signal(SIGINT,signal_handler); signal(SIGTERM,signal_handler);
 int gpu_num=0; size_t user_work=0, user_block=0;
 if(argc>=2) gpu_num=atoi(argv[1]); if(argc>=3) user_work=strtoull(argv[2],nullptr,10); if(argc>=4) user_block=strtoull(argv[3],nullptr,10);
 int ndev=0; CUDA_CHECK(cudaGetDeviceCount(&ndev)); if(ndev<=0){fprintf(stderr,"No CUDA GPU found.\n");return 1;}
 print_timestamp(); printf("BTCW CUDA miner for BitcoinPoW Core 31.x from block 144444 (32-bit RFC6979 test_case, live signature target, sign-batch%d)\n",SIGN_BATCH);
 print_timestamp(); printf("Usage: btcw_cuda_miner [gpu] [work_size] [block_size] [64-hex signaturetarget]\n");
 print_timestamp(); printf("Found %d CUDA device(s):\n",ndev);
 for(int i=0;i<ndev;i++){ cudaDeviceProp p{}; CUDA_CHECK(cudaGetDeviceProperties(&p,i)); printf("  Device %d: %s SMs=%d Mem=%zuMB MaxBlock=%d CC=%d.%d\n",i,p.name,p.multiProcessorCount,p.totalGlobalMem/(1024*1024),p.maxThreadsPerBlock,p.major,p.minor); }
 int dev=gpu_num; if(dev<0||dev>=ndev){fprintf(stderr,"GPU %d not found. Pass the 0-based device number printed above.\n",gpu_num);return 1;} CUDA_CHECK(cudaSetDevice(dev));
 cudaDeviceProp prop{}; CUDA_CHECK(cudaGetDeviceProperties(&prop,dev));
 print_timestamp(); printf("Using device %d: %s (%d SMs, %zuMB)\n",dev,prop.name,prop.multiProcessorCount,prop.totalGlobalMem/(1024*1024));
 uint *d_rfc_ok=nullptr, h_rfc_ok=0; CUDA_CHECK(cudaMalloc((void**)&d_rfc_ok,sizeof(uint)));
 diagnostic_rfc6979_testcase<<<1,1>>>(d_rfc_ok); CUDA_CHECK(cudaGetLastError());
 CUDA_CHECK(cudaMemcpy(&h_rfc_ok,d_rfc_ok,sizeof(uint),cudaMemcpyDeviceToHost)); cudaFree(d_rfc_ok);
 if(!h_rfc_ok){fprintf(stderr,"Fatal: optimized RFC6979 extra-entropy self-test failed.\n");return 1;}
 print_timestamp(); printf("RFC6979 extra-entropy fast path self-test passed.\n");
 {
   // Public test key 1. Not a wallet key.
   const uchar sk[32]={0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1};
   const uchar msg[32]={0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31};
   const uchar exp_r[32]={0x89,0x3d,0x1f,0xef,0x3d,0xdc,0xdd,0x87,0xd0,0xeb,0x0e,0x01,0xc1,0x1c,0xa0,0xf3,0xde,0x89,0xe9,0x64,0x4d,0xdc,0xfb,0x7f,0xaf,0x45,0x33,0x0a,0x13,0x12,0xee,0x05};
   const uchar exp_s[32]={0x75,0x52,0x87,0xee,0xc1,0x9e,0x3f,0xea,0x98,0x62,0xb9,0x19,0x6c,0x78,0x56,0xf7,0x9b,0x72,0xee,0xb6,0x23,0x76,0x90,0x6b,0x94,0x39,0x4e,0x63,0xdb,0xdf,0xad,0x22};
   uchar *dsk=nullptr,*dmsg=nullptr,*dr=nullptr,*ds=nullptr; uint *dflags=nullptr;
   CUDA_CHECK(cudaMalloc((void**)&dsk,32)); CUDA_CHECK(cudaMalloc((void**)&dmsg,32));
   CUDA_CHECK(cudaMalloc((void**)&dr,32)); CUDA_CHECK(cudaMalloc((void**)&ds,32)); CUDA_CHECK(cudaMalloc((void**)&dflags,sizeof(uint)));
   CUDA_CHECK(cudaMemcpy(dsk,sk,32,cudaMemcpyHostToDevice)); CUDA_CHECK(cudaMemcpy(dmsg,msg,32,cudaMemcpyHostToDevice));
   diagnostic_mining_ecdsa<<<1,1>>>(dsk,dmsg,1u,dr,ds,dflags);
   CUDA_CHECK(cudaGetLastError()); CUDA_CHECK(cudaDeviceSynchronize());
   uchar hr[32],hs[32]; uint flags=0;
   CUDA_CHECK(cudaMemcpy(hr,dr,32,cudaMemcpyDeviceToHost)); CUDA_CHECK(cudaMemcpy(hs,ds,32,cudaMemcpyDeviceToHost));
   CUDA_CHECK(cudaMemcpy(&flags,dflags,sizeof(uint),cudaMemcpyDeviceToHost));
   cudaFree(dsk); cudaFree(dmsg); cudaFree(dr); cudaFree(ds); cudaFree(dflags);
   print_timestamp();
   printf("ECDSA diag flags=%u mul3x7=%s fermat2=%s finish=%s r=%s s=%s\n",
          flags, (flags&1)?"ok":"FAIL", (flags&2)?"ok":"FAIL", (flags&4)?"ok":"FAIL",
          memcmp(hr,exp_r,32)==0?"ok":"FAIL", memcmp(hs,exp_s,32)==0?"ok":"FAIL");
   if(memcmp(hr,exp_r,32)!=0 || memcmp(hs,exp_s,32)!=0){
     printf("  got_r="); for(int i=0;i<32;i++) printf("%02x",hr[i]); printf("\n");
     printf("  got_s="); for(int i=0;i<32;i++) printf("%02x",hs[i]); printf("\n");
   }
   if(!(flags&1) || !(flags&2) || !(flags&4) || memcmp(hr,exp_r,32)!=0 || memcmp(hs,exp_s,32)!=0){
     fprintf(stderr,"Fatal: mining ECDSA path does not match libsecp256k1.\n");
     return 1;
   }
 }
 cudaFuncAttributes attr{}; CUDA_CHECK(cudaFuncGetAttributes(&attr,btcw_mine));
 print_timestamp(); printf("=== CUDA KERNEL RESOURCE PROFILE ===\n");
 printf("Max threads/block          : %d\n",attr.maxThreadsPerBlock); printf("Registers/thread           : %d\n",attr.numRegs); printf("Static shared memory       : %zu bytes\n",attr.sharedSizeBytes); printf("Local spill bytes/thread   : %zu bytes\n",attr.localSizeBytes); printf("Compute capability         : %d.%d\n",prop.major,prop.minor); printf("====================================\n");

 const size_t EN[6]={8388608ULL,8388608ULL,8388608ULL,8388608ULL,8388608ULL,256ULL};
 ulong* dtab[6]={};
 print_timestamp(); printf("Allocating/precomputing GLV W24/W9 generator table (~2560 MiB)...\n");
 for(int i=0;i<6;i++){ size_t bytes=EN[i]*8ULL*sizeof(ulong); CUDA_CHECK(cudaMalloc((void**)&dtab[i],bytes)); uint entries=(uint)EN[i]; int t=256; size_t b=(EN[i]+t-1)/t; printf("  group %d/6: %u entries (%zu MiB)\n",i+1,entries,bytes/(1024*1024)); precompute_ecmult_gen_table<<<(unsigned)b,t>>>(dtab[i],(uint)i,entries); CUDA_CHECK(cudaGetLastError()); CUDA_CHECK(cudaDeviceSynchronize()); }
 print_timestamp(); printf("Ecmult table ready (GLV W24/W9, 6 groups, ~2560 MiB).\n");

 uchar *dkey=nullptr,*dhash=nullptr,*dtarget=nullptr; ulong* dnonce=nullptr; uint *dfound=nullptr,*dctr=nullptr;
 CUDA_CHECK(cudaMalloc((void**)&dkey,32)); CUDA_CHECK(cudaMalloc((void**)&dhash,32)); CUDA_CHECK(cudaMalloc((void**)&dtarget,32)); CUDA_CHECK(cudaMalloc((void**)&dnonce,sizeof(ulong))); CUDA_CHECK(cudaMalloc((void**)&dfound,sizeof(uint))); CUDA_CHECK(cudaMalloc((void**)&dctr,sizeof(uint)));

#ifdef _WIN32
 HANDLE mapping=CreateFileMappingA(INVALID_HANDLE_VALUE,nullptr,PAGE_READWRITE,0,(DWORD)sizeof(SharedData),SHM_NAME);
 if(!mapping){fprintf(stderr,"CreateFileMapping('%s') failed (%lu)\n",SHM_NAME,GetLastError());return 1;}
 SharedData* shared=(SharedData*)MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(SharedData));
 if(!shared){fprintf(stderr,"MapViewOfFile failed (%lu)\n",GetLastError());CloseHandle(mapping);return 1;}
#else
 int shm_fd=shm_open(SHM_NAME,O_RDWR,0600); if(shm_fd==-1){ shm_fd=shm_open(SHM_NAME,O_CREAT|O_RDWR,0600); if(shm_fd==-1){perror("shm_open");return 1;} if(ftruncate(shm_fd,sizeof(SharedData))==-1){perror("ftruncate");return 1;} }
 SharedData* shared=(SharedData*)mmap(nullptr,sizeof(SharedData),PROT_READ|PROT_WRITE,MAP_SHARED,shm_fd,0); if(shared==MAP_FAILED){perror("mmap");return 1;}
#endif
 print_timestamp(); printf("Shared memory '%s' mapped successfully.\n",SHM_NAME);

 size_t block=user_block?user_block:128; if(block>1024||block==0){fprintf(stderr,"Invalid CUDA block size %zu\n",block);return 1;}
 size_t work=user_work?user_work:(size_t)prop.multiProcessorCount*9728ULL; if(work<65536)work=65536; if(work>4194304)work=4194304; if(work%block)work=((work+block-1)/block)*block;
 print_timestamp(); printf("Work size: %zu%s\n",work,user_work?" (manual override)":" (v40 tuned mapping)"); print_timestamp(); printf("CUDA block size: %zu%s\n",block,user_block?" (manual override)":"");
 constexpr size_t SIGN_BATCH_HOST=SIGN_BATCH; size_t scratch_bytes=work*SIGN_BATCH_HOST*sizeof(Scalar); Scalar* dscratch=nullptr; FieldElement* drxscratch=nullptr; CUDA_CHECK(cudaMalloc((void**)&dscratch,scratch_bytes)); if(BTCW_HYBRID_RX)CUDA_CHECK(cudaMalloc((void**)&drxscratch,scratch_bytes)); print_timestamp(); printf("K/Rx scratch: %.2f / %.2f GiB global\n",(double)scratch_bytes/(1024.0*1024.0*1024.0),drxscratch?(double)scratch_bytes/(1024.0*1024.0*1024.0):0.0);

 // Search Hash(DER) against the node's real Stage-2 target so a submitted
 // 32-bit test_case is one CKey::Sign(grind=false, nonce) will accept.
 uint8_t hkey[32]={}, hhash[32]={}, prevhash[32]={};
 uint8_t htarget[32]={}, last_target[32]={};
 const char* target_src="none";
 if(!load_signature_target(argc,argv,htarget,&target_src)){
   fprintf(stderr,
     "Fatal: no live Stage-2 signature target.\n"
     "This miner searches the target BitcoinPoW Core 31.x publishes in getmininginfo\n"
     "as next.signaturetarget. A synced node on the block 144444 rules is required.\n"
     "Fix one of these, then start the miner again:\n"
     "  bitcoin-cli getmininginfo\n"
     "  set BTCW_CLI to your bitcoin-cli, and BTCW_DATADIR if the node is not in the default datadir\n"
     "  or set BTCW_SIG_TARGET to the 64-hex next.signaturetarget\n"
     "  or pass that hex as the 4th argument\n"
     "  or write it as one line in target.txt\n");
   return 1;
 }
 char target_hex[65]; target_to_hex(htarget,target_hex);
 print_timestamp(); printf("Signature target %s (source=%s). GPU Hash(DER) must match node CKey::Sign.\n",target_hex,target_src);
 memcpy(last_target,htarget,32);
 CUDA_CHECK(cudaMemcpy(dtarget,htarget,32,cudaMemcpyHostToDevice)); bool havehash=false,was_connected=false,conn_printed=false,disconnect_timing=false; auto disconnect_start=std::chrono::steady_clock::now(); const int DISCONNECT_SECONDS=3; int block_transitions=0; uint64_t nonce_prev=1234,hashlow=0,nonce_base=0; uint32_t throttle=0; uint64_t shares=0; int refresh_ticks=0; auto session_start=std::chrono::steady_clock::now();
 print_timestamp(); printf("GPU initialized - waiting for block data...\n");
 while(g_running.load()){
   uint64_t changeCount=0; auto start=std::chrono::steady_clock::now();
   if((refresh_ticks++ % 10)==0){
     uint8_t refreshed[32]; const char* rsrc=target_src;
     bool got=fetch_target_rpc(refreshed);
     if(!got){ const char* tf=std::getenv("BTCW_TARGET_FILE"); if(!tf||!tf[0]) tf="target.txt"; if(load_target_file(tf,refreshed)){got=true;rsrc="file";} }
     if(got && memcmp(refreshed,last_target,32)!=0){
       memcpy(htarget,refreshed,32); memcpy(last_target,refreshed,32); target_src=rsrc;
       target_to_hex(htarget,target_hex);
       CUDA_CHECK(cudaMemcpy(dtarget,htarget,32,cudaMemcpyHostToDevice));
       print_timestamp(); printf("Signature target updated %s (source=%s)\n",target_hex,target_src);
     }
   }
   while(g_running.load() && std::chrono::steady_clock::now()-start<std::chrono::seconds(2)){
     if((throttle%3)==0){ memcpy(hkey,(const void*)&shared->data[0],32); memcpy(hhash,(const void*)&shared->data[192],32); if(!havehash){memcpy(prevhash,hhash,32);havehash=true;} else if(memcmp(hhash,prevhash,32)!=0){memcpy(prevhash,hhash,32);block_transitions++;nonce_base=0;shared->nonce=SENTINEL_NONCE;nonce_prev=SENTINEL_NONCE;print_timestamp();printf("New block data from node (block #%d this session)\n",block_transitions);} CUDA_CHECK(cudaMemcpyAsync(dkey,hkey,32,cudaMemcpyHostToDevice)); CUDA_CHECK(cudaMemcpyAsync(dhash,hhash,32,cudaMemcpyHostToDevice)); }
     throttle++;
     CUDA_CHECK(cudaMemsetAsync(dnonce,0,sizeof(ulong))); CUDA_CHECK(cudaMemsetAsync(dfound,0,sizeof(uint))); CUDA_CHECK(cudaMemsetAsync(dctr,0,sizeof(uint)));
     size_t blocks=work/block;
     btcw_mine<<<(unsigned)blocks,(unsigned)block>>>(dkey,dhash,dnonce,dfound,dctr,(ulong)nonce_base,(uint)gpu_num,dtab[0],dtab[1],dtab[2],dtab[3],dtab[4],dtab[5],dtarget,dscratch,drxscratch);
     CUDA_CHECK(cudaGetLastError());
     uint result_found=0,ctr=0; ulong result_nonce=0; CUDA_CHECK(cudaMemcpy(&result_found,dfound,sizeof(uint),cudaMemcpyDeviceToHost)); CUDA_CHECK(cudaMemcpy(&result_nonce,dnonce,sizeof(ulong),cudaMemcpyDeviceToHost)); CUDA_CHECK(cudaMemcpy(&ctr,dctr,sizeof(uint),cudaMemcpyDeviceToHost)); changeCount+=ctr;
     if(result_found){shares++;shared->nonce=result_nonce;nonce_prev=result_nonce;print_timestamp();printf("GPU share nonce=%08llx submitted (Hash(DER) <= node target). shares=%llu\n",(unsigned long long)result_nonce,(unsigned long long)shares);}
     nonce_base = (nonce_base + work*128ULL) & 0xFFFFFFFFULL; if(nonce_base==0) nonce_base=1;
     memcpy(&hashlow,(const void*)&shared->data[192],8);
     if(hashlow==0){ if(!disconnect_timing){disconnect_start=std::chrono::steady_clock::now();disconnect_timing=true;} if(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now()-disconnect_start).count()>=DISCONNECT_SECONDS){ if(conn_printed||!was_connected){print_timestamp();printf("!!! NOT CONNECTED TO BTCW NODE WALLET !!! Turn staking on. The wallet needs a legacy address (starts with 1) with at least 6 confirmations.\n");conn_printed=false;} std::this_thread::sleep_for(std::chrono::seconds(1)); }} else { if(!was_connected||!conn_printed){print_timestamp();printf("Connected to BTCW node wallet\n");conn_printed=true;} disconnect_timing=false;was_connected=true; }
   }
   double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count(); double mh=(elapsed>0)?(double)changeCount/elapsed/1e6:0; auto up=std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now()-session_start).count(); print_timestamp(); printf("Mining | %.2f MH/s | Nonce: %016llx | Shares: %llu | Work: %d | Up: %02lld:%02lld:%02lld\n",mh,(unsigned long long)shared->nonce,(unsigned long long)shares,block_transitions,(long long)(up/3600),(long long)((up/60)%60),(long long)(up%60)); fflush(stdout);
 }
 print_timestamp(); printf("Shutting down...\n");
 cudaFree(drxscratch); cudaFree(dscratch); cudaFree(dkey); cudaFree(dhash); cudaFree(dtarget); cudaFree(dnonce); cudaFree(dfound); cudaFree(dctr); for(auto p:dtab)cudaFree(p);
#ifdef _WIN32
 UnmapViewOfFile((void*)shared); CloseHandle(mapping);
#else
 munmap(shared,sizeof(SharedData)); close(shm_fd);
#endif
 print_timestamp();printf("Goodbye.\n"); return 0;
}
