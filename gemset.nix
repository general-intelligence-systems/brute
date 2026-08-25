{
  activesupport = {
    dependencies = ["base64" "bigdecimal" "concurrent-ruby" "connection_pool" "drb" "i18n" "json" "logger" "minitest" "securerandom" "tzinfo" "uri"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "03m2vjhq3nmc8c3hpivxhvkjd8igg16nmv0p2fgdsgacppgy1991";
      type = "gem";
    };
    version = "8.1.3";
  };
  addressable = {
    dependencies = ["public_suffix"];
    groups = ["browser" "completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1by7h2lwziiblizpd5yx87jsq8ppdhzvwf08ga34wzqgcv1nmpvz";
      type = "gem";
    };
    version = "2.9.0";
  };
  anthropic = {
    dependencies = ["cgi" "connection_pool" "standardwebhooks"];
    groups = ["completions"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1k1ys4z4cz030mm8cp4as6f00d0jl0570fm8qw9iscqmkm52d09f";
      type = "gem";
    };
    version = "1.55.0";
  };
  async = {
    dependencies = ["console" "fiber-annotation" "io-event" "metrics" "traces"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1ah038cvb5k7vr29z5jkjhdwqpinrchglz87i1bv9fzjfc07666z";
      type = "gem";
    };
    version = "2.39.0";
  };
  baran = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "155gh8q8jqvfgsd6l1hwf8p3wjwwvlin2grbbavnyl677cn3dh9j";
      type = "gem";
    };
    version = "0.1.12";
  };
  base64 = {
    groups = ["browser" "completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0yx9yn47a8lkfcjmigk79fykxvr80r4m1i35q82sxzynpbm7lcr7";
      type = "gem";
    };
    version = "0.3.0";
  };
  bigdecimal = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1g9zi8c4i7g8zz0c3hxrw6mblrjvgn7akys60clb9si7c1k1gljk";
      type = "gem";
    };
    version = "4.1.2";
  };
  brute = {
    dependencies = ["activesupport" "async" "colorize-extended" "diff-lcs" "file-tail" "gem_kit" "google-protobuf" "json" "json_schemer" "net-http-persistent" "rack"];
    groups = ["default"];
    platforms = [];
    source = {
      path = ./.;
      type = "path";
    };
    version = "5.1.0";
  };
  cgi = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1fzqwshg1xzbdm97havskfp6wifsgbjii00dzba0y6bih4lk1jk1";
      type = "gem";
    };
    version = "0.5.2";
  };
  colorize = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0dy8ryhcdzgmbvj7jpa1qq3bhhk1m7a2pz6ip0m6dxh30rzj7d9h";
      type = "gem";
    };
    version = "1.1.0";
  };
  colorize-extended = {
    dependencies = ["colorize"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1jgdgggz10ad5fm2sfg15wyvix0yhp7h5yn84d3f3qhywj39khz8";
      type = "gem";
    };
    version = "0.1.0";
  };
  concurrent-ruby = {
    groups = ["browser" "completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1c2i64xsd35vijnb50rxb70g508s0x674xi0qpyyb8jy7bncl4j4";
      type = "gem";
    };
    version = "1.3.7";
  };
  connection_pool = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "02ifws3c4x7b54fv17sm4cca18d2pfw1saxpdji2lbd1f6xgbzrk";
      type = "gem";
    };
    version = "3.0.2";
  };
  console = {
    dependencies = ["fiber-annotation" "fiber-local" "json"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1k0dxi072mz8j72r32kkzpky825hn092hb8hdxh4rz3yd5sbv7w6";
      type = "gem";
    };
    version = "1.34.3";
  };
  csv = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0gz7r2kazwwwyrwi95hbnhy54kwkfac5swh2gy5p5vw36fn38lbf";
      type = "gem";
    };
    version = "3.3.5";
  };
  diff-lcs = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1mb3nfmnv5gyaxcw10fzdr4jrvx198bq38akiw7vai99xi95v2kh";
      type = "gem";
    };
    version = "2.0.0";
  };
  dotenv = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "17b1zr9kih0i3wb7h4yq9i8vi6hjfq07857j437a8z7a44qvhxg3";
      type = "gem";
    };
    version = "3.2.0";
  };
  drb = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0wrkl7yiix268s2md1h6wh91311w95ikd8fy8m5gx589npyxc00b";
      type = "gem";
    };
    version = "2.2.3";
  };
  erb = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "14pfj6zn0p1hxj6s6s0r7d424wap8zl9zxf89nj79y8fbg16vjn5";
      type = "gem";
    };
    version = "6.0.7";
  };
  event_stream_parser = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1j73glgif3f97q3znq9ih67h5i7zd1wqzj2d33w8cqhjf2mkns52";
      type = "gem";
    };
    version = "1.0.0";
  };
  faraday = {
    dependencies = ["faraday-net_http" "json" "logger"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0y7j6yzv07zggic6g0p2v1ivnvkzsbqjnfdl4215qqb6cxz290hq";
      type = "gem";
    };
    version = "2.14.3";
  };
  faraday-multipart = {
    dependencies = ["multipart-post"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0mzp9rlqiryyi99bm9ii80hfsbbafh9wl8r3c5pif51pd54sk2bx";
      type = "gem";
    };
    version = "1.2.0";
  };
  faraday-net_http = {
    dependencies = ["net-http"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "125m3qri52vwh5v9dhq0dkqxf8629cxrf99yyc01pva72wasyy0f";
      type = "gem";
    };
    version = "3.4.4";
  };
  faraday-retry = {
    dependencies = ["faraday"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1ghys6d46j8mxkqprnlz1ks1y1w0lsa2vca7ybx2crg5ny7w8ybv";
      type = "gem";
    };
    version = "2.4.0";
  };
  ferrum = {
    dependencies = ["addressable" "base64" "concurrent-ruby" "webrick" "websocket-driver"];
    groups = ["browser"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1vp62wy85hr5fa0d29y3wh3zaj10sszj3pl19mps84dja2l4099c";
      type = "gem";
    };
    version = "0.17.2";
  };
  fiber-annotation = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "00vcmynyvhny8n4p799rrhcx0m033hivy0s1gn30ix8rs7qsvgvs";
      type = "gem";
    };
    version = "0.2.0";
  };
  fiber-local = {
    dependencies = ["fiber-storage"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "01lz929qf3xa90vra1ai1kh059kf2c8xarfy6xbv1f8g457zk1f8";
      type = "gem";
    };
    version = "1.1.0";
  };
  fiber-storage = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1qa0j9qjwav9xb0n3isx0rbh0942xrfback392n6vs8bidnmp3pl";
      type = "gem";
    };
    version = "1.0.1";
  };
  file-tail = {
    dependencies = ["tins"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0z8vjkxc28cis6k48ps7isjnaa72ifmhkyq6ciz1vlfyw56i1cv0";
      type = "gem";
    };
    version = "1.4.0";
  };
  gem_kit = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0dx9w041lqzr4jd0m9as0v5v6n3fj2hcg74p2gyswr2y2a6zc5v9";
      type = "gem";
    };
    version = "0.2.0";
  };
  gem_kit-release = {
    dependencies = ["gem_kit" "thor"];
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0f2n3kfvmsssdnizybbsiiwlycnk8lf8x70vh61f0aszmxbid9vn";
      type = "gem";
    };
    version = "0.3.1";
  };
  google-protobuf = {
    dependencies = ["bigdecimal" "rake"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1p3cg5sf7if5vf17glhsm58ydk6cr68kgyi8y1h9qrcd5da82w9l";
      type = "gem";
    };
    version = "4.34.1";
  };
  hana = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "03cvrv2wl25j9n4n509hjvqnmwa60k92j741b64a1zjisr1dn9al";
      type = "gem";
    };
    version = "1.3.7";
  };
  i18n = {
    dependencies = ["concurrent-ruby"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1994i044vdmzzkyr76g8rpl1fq1532wf0sb21xg5r1ilj5iphmr8";
      type = "gem";
    };
    version = "1.14.8";
  };
  io-console = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "026v93kja19bfslnwi9xfq2dj4r89kkwdprim4whjg6h3n4lz9zg";
      type = "gem";
    };
    version = "0.9.2";
  };
  io-event = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1k1hkgjjnxa9xa023904n9diyirm5x4z92sm7zb1ah15937wsi66";
      type = "gem";
    };
    version = "1.15.1";
  };
  irb = {
    dependencies = ["pp" "prism" "rdoc" "reline"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1qs8a9vprg7s8krgq4s0pygr91hclqqyz98ik15p0m1sf2h5956y";
      type = "gem";
    };
    version = "1.18.0";
  };
  json = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0shwgjqbj856mb6m9kgkpy08nhym2gdvc2yaprlimfmky9y3n78z";
      type = "gem";
    };
    version = "2.21.2";
  };
  json-schema = {
    dependencies = ["addressable"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "09bq393nrxa7hmphc3li8idgxdnb5hwgj15d0q5qsh4l5g1qvrnm";
      type = "gem";
    };
    version = "4.3.1";
  };
  json_schemer = {
    dependencies = ["bigdecimal" "hana" "regexp_parser" "simpleidn"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "15p31bq932bfpsi1wgrkgwm71l7z1h1w53q6vl44w6kjrr6gn09g";
      type = "gem";
    };
    version = "2.5.0";
  };
  langchainrb = {
    dependencies = ["baran" "csv" "json-schema" "matrix" "pragmatic_segmenter" "zeitwerk"];
    groups = ["completions"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0y85wf9mfyq4j2pwdbgaxjk3yqqdcp8kwfsnclhai7gr1pikmsw5";
      type = "gem";
    };
    version = "0.19.5";
  };
  lefthook = {
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0r8vwq96i3wfsb3c2q0qjl3nssadwmlrgavf06wfi2d6isyhd76c";
      type = "gem";
    };
    version = "2.1.10";
  };
  "llm.rb" = {
    groups = ["completions"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1bj4f3bj95ws37w5njh7cd26hcmdf28qzlq3hwq6d12m1d8fjm3x";
      type = "gem";
    };
    version = "11.2.0";
  };
  logger = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "00q2zznygpbls8asz5knjvvj2brr3ghmqxgr83xnrdj4rk3xwvhr";
      type = "gem";
    };
    version = "1.7.0";
  };
  marcel = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1vhb1sbzlq42k2pzd9v0w5ws4kjx184y8h4d63296bn57jiwzkzx";
      type = "gem";
    };
    version = "1.1.0";
  };
  matrix = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0nscas3a4mmrp1rc07cdjlbbpb2rydkindmbj3v3z5y1viyspmd0";
      type = "gem";
    };
    version = "0.4.3";
  };
  metrics = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0wlh0g4xmfqa41dsh4m3514q3jcvy6jx97mwn6ayj62ir6xdbpk1";
      type = "gem";
    };
    version = "0.15.0";
  };
  minitest = {
    dependencies = ["drb" "prism"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0p0m046nqiwwvq3bm44wvhf8ba5bqvbjr102jmafmzpldcjdf1zh";
      type = "gem";
    };
    version = "6.0.5";
  };
  mize = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "105pjjmncf7q724swbygrbsgmh74ni4s2xaclbyjcm7zg64maca0";
      type = "gem";
    };
    version = "0.6.1";
  };
  multipart-post = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1a5lrlvmg2kb2dhw3lxcsv6x276bwgsxpnka1752082miqxd0wlq";
      type = "gem";
    };
    version = "2.4.1";
  };
  net-http = {
    dependencies = ["uri"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "15k96fj6qwbaiv6g52l538ass95ds1qwgynqdridz29yqrkhpfi5";
      type = "gem";
    };
    version = "0.9.1";
  };
  net-http-persistent = {
    dependencies = ["connection_pool"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1rk03449disq3azyiymv1c3qnpqr6cxawgq556rkf5b9klqyhggg";
      type = "gem";
    };
    version = "4.0.8";
  };
  open_router_enhanced = {
    dependencies = ["activesupport" "dotenv" "faraday" "faraday-multipart" "json-schema"];
    groups = ["completions"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1zcn5ry9qnm9rifh5i0qbi9m8c2ny97f68g3rmixv76wyqwg1m35";
      type = "gem";
    };
    version = "2.3.0";
  };
  openai = {
    dependencies = ["base64" "cgi" "connection_pool"];
    groups = ["completions"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1cv35sjfzjs481lw1kwm8jvknbka48az0m3151ybg4ajpnx45dgv";
      type = "gem";
    };
    version = "0.68.0";
  };
  pp = {
    dependencies = ["prettyprint"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0w5mha75hs8gdj75g8vl0sxpyp8rzvwq8a4jcmi4ah8cf370zjyz";
      type = "gem";
    };
    version = "0.6.4";
  };
  pragmatic_segmenter = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1j9l8pppmcc3gyvrj9wk2vqydb43n3pgfsy2h5mcs1pw7sahjdrw";
      type = "gem";
    };
    version = "0.3.24";
  };
  prettyprint = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "14zicq3plqi217w6xahv7b8f7aj5kpxv1j1w98344ix9h5ay3j9b";
      type = "gem";
    };
    version = "0.2.0";
  };
  prism = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "11ggfikcs1lv17nhmhqyyp6z8nq5pkfcj6a904047hljkxm0qlvv";
      type = "gem";
    };
    version = "1.9.0";
  };
  public_suffix = {
    groups = ["browser" "completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "08znfv30pxmdkjyihvbjqbvv874dj3nybmmyscl958dy3f7v12qs";
      type = "gem";
    };
    version = "7.0.5";
  };
  rack = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1hhjy9gcp52dzij05gmidqac8g28ski5xm67prwmdqmjfcgqxmsy";
      type = "gem";
    };
    version = "3.2.6";
  };
  rake = {
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "009p524zl0p0kfa65nii8wdmaigkmawv9pbvlcffky7islmmp0nb";
      type = "gem";
    };
    version = "13.4.2";
  };
  rbs = {
    dependencies = ["logger" "prism" "tsort"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1i5qp9yqccjr8jq865n3qayknckq6vjv7l7s9cv19p0wfnlp8i0c";
      type = "gem";
    };
    version = "4.1.3";
  };
  rdoc = {
    dependencies = ["erb" "prism" "rbs" "tsort"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0sf4909q2mr9z0rpygv94z12b0yamg07gz8cba2mi5k3m448rgq3";
      type = "gem";
    };
    version = "8.0.0";
  };
  readline = {
    dependencies = ["reline"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0shxkj3kbwl43rpg490k826ibdcwpxiymhvjnsc85fg2ggqywf31";
      type = "gem";
    };
    version = "0.0.4";
  };
  regexp_parser = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1fwfw26a32rps78920nn29shqg2zmqv72i89j1fap41isshida9m";
      type = "gem";
    };
    version = "2.12.0";
  };
  reline = {
    dependencies = ["io-console"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0gaq2lc463ap1srz7y5kh2p4dxazs7vjrpiby58d9yfvan72s0av";
      type = "gem";
    };
    version = "0.7.0";
  };
  ruby_llm = {
    dependencies = ["base64" "event_stream_parser" "faraday" "faraday-multipart" "faraday-net_http" "faraday-retry" "marcel" "ruby_llm-schema" "zeitwerk"];
    groups = ["completions"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0065wyf1fk0a7hs5a9gb49mhldrp0vhmdmikj9nq71lypgqd11vl";
      type = "gem";
    };
    version = "1.14.1";
  };
  ruby_llm-schema = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1inylgysslw1apvmr7z0gfhvxcx43gk1s9p2y0206zqvrb2yv4d5";
      type = "gem";
    };
    version = "0.3.0";
  };
  scampi = {
    groups = ["development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "04x366dnw081ajg6qbw24i6afisv7fsgyvvwnvlr000ah48k3d66";
      type = "gem";
    };
    version = "1.0.0";
  };
  securerandom = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1cd0iriqfsf1z91qg271sm88xjnfd92b832z49p1nd542ka96lfc";
      type = "gem";
    };
    version = "0.4.1";
  };
  simpleidn = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0a9c1mdy12y81ck7mcn9f9i2s2wwzjh1nr92ps354q517zq9dkh8";
      type = "gem";
    };
    version = "0.2.3";
  };
  standardwebhooks = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "07z19dg85pdsr9038b114prwqp5x4qxidr0hffr4zvsdq48sfsrm";
      type = "gem";
    };
    version = "1.1.0";
  };
  sync = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1z9qlq4icyiv3hz1znvsq1wz2ccqjb1zwd6gkvnwg6n50z65d0v6";
      type = "gem";
    };
    version = "0.5.0";
  };
  thor = {
    groups = ["default" "development"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0wsy88vg2mazl039392hqrcwvs5nb9kq8jhhrrclir2px1gybag3";
      type = "gem";
    };
    version = "1.5.0";
  };
  tins = {
    dependencies = ["bigdecimal" "irb" "mize" "readline" "sync"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0vml57h2fw7c97cpchk67jbychsmyzmf9bfjmdilpzdqra0wzrjs";
      type = "gem";
    };
    version = "1.56.0";
  };
  traces = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "05722prvh34n96irnxa762wz0yj2nyrz70ab2zby3b6snjf69wc0";
      type = "gem";
    };
    version = "0.18.2";
  };
  tsort = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "17q8h020dw73wjmql50lqw5ddsngg67jfw8ncjv476l5ys9sfl4n";
      type = "gem";
    };
    version = "0.2.0";
  };
  tzinfo = {
    dependencies = ["concurrent-ruby"];
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "16w2g84dzaf3z13gxyzlzbf748kylk5bdgg3n1ipvkvvqy685bwd";
      type = "gem";
    };
    version = "2.0.6";
  };
  uri = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1ijpbj7mdrq7rhpq2kb51yykhrs2s54wfs6sm9z3icgz4y6sb7rp";
      type = "gem";
    };
    version = "1.1.1";
  };
  webrick = {
    groups = ["browser" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0ca1hr2rxrfw7s613rp4r4bxb454i3ylzniv9b9gxpklqigs3d5y";
      type = "gem";
    };
    version = "1.9.2";
  };
  websocket-driver = {
    dependencies = ["base64" "websocket-extensions"];
    groups = ["browser"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0ij19k6034x0c4hw0ywa7wnk5s912r8aq0hhjss10d5z36q5dicp";
      type = "gem";
    };
    version = "0.8.2";
  };
  websocket-extensions = {
    groups = ["browser" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0hc2g9qps8lmhibl5baa91b4qx8wqw872rgwagml78ydj8qacsqw";
      type = "gem";
    };
    version = "0.1.5";
  };
  zeitwerk = {
    groups = ["completions" "default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1pbkiwwla5gldgb3saamn91058nl1sq1344l5k36xsh9ih995nnq";
      type = "gem";
    };
    version = "2.7.5";
  };
}
