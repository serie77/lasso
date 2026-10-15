// Copy to config.js (gitignored) and set rpc. Shared frontend config. Everything here is public: the browser has to see it to talk to the chain.
// rpc: paste your Alchemy URL here (and allowlist your domain in Alchemy), or point it at keeper/rpc-proxy.mjs
// to keep the key off the client entirely.
window.LASSO = {
  rpc: 'https://rpc.mainnet.chain.robinhood.com',
  chainId: 4663,
  explorer: 'https://robinhoodchain.blockscout.com',
  lasso: '0xcBBe708dce939f2772B70967c1D0EB8e11b5DC27',
  lp: '0xBD380F2C9829816EDAc44335a7a081f3cd557FDb',
  farm: '0xC97493E716190bFC2cc7479ed28041EA295B1695',
  adapter: '0xfF915229f38f74fe57410deB901Efb2ADe684c56',
  usdg: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',
  registry: '0x33c5341DC45E389B2A993F4599649D121646240C',
  poolManager: '0x8366a39CC670B4001A1121B8F6A443A643e40951',
  feeHook: '0xb51d89BBc50B5AE469be8CFbF305CAb6ff3A50Cc',
  hxmaxPoolId: '0x4be9bdfcff70326169d9a871974f0e15d18d07ce424678c40aaeef295decb1ae',
};
