# vim-vp4 开发笔记

本文件记录项目开发过程中非显而易见的设计决策与踩坑，供后续维护参考。随 git 一起提交。

## 2026-09-11 · Vp4AnnotateLine 跨分支溯源

### 背景

`Vp4AnnotateLine` 原本用 `p4 annotate -cI` 追一跳 integrate 链，但追不了跨 stream 的
branch/copy/move/merge。当某行是从别的 stream 分支/合并过来（往往是 NGRBuild /
NGRAutoMerge 机器人提交）时，annotate 停在机器人 CL 上，拿不到实际提交者。

对齐 `~/git/ngr-cs/crosscheck/server-result/blame_dt_owner.py` 的
`blame_across_branches` 逻辑：机器人提交 → 解析 CL 描述的 `Origin: {'user': ...}` 或
`Branching/Copy/Merge from //src`，沿源 stream 逐层跳转直到真人。

真实案例（验证用）—— `~/work/ngr/Server/Source/Resource/PlateauResource.cpp:832`：

```
832 行 → CL 6855861  branch (NGRBuild)  //Trunk_S3/...#1
       → CL 2436295  merge  (NGRBuild)  //1.6_Trunk/...#2
       → CL 2432854  edit   (krooswang) //Trunk  ← 原始 CL
```

### 设计决策（用户拍板）

- **触发条件**：当 annotate 命中 CL 的提交者在机器人列表（`g:vp4_annotate_bot_users`，
  默认 `NGRBuild`/`NGRAutoMerge`）时继续追；否则停（已追到真人）。
- **沿源 stream 追到原始 CL**：机器人 CL 始终沿 `Branching/Copy/Merge from //src` remap
  到源 stream 继续追，直到追到非机器人提交者（这才是原始 CL）。`Origin: {'user': '真人'}`
  只作为追不动时的兜底标记（merge 的 filelog 没有 `from` 行，源信息在描述里）。
- **源 stream 跳转**：无 Origin 时，从描述解析 `Branching/Copy/Merge from //src`，remap
  到源 stream，再内容匹配继续。
- **跨分支行定位**：跳到源分支后，**按光标行的文本内容**在源文件 annotate 输出里精确
  匹配；**恰好 1 个命中**才继续，0 或多命中则放弃、保持当前 CL。

### 实现要点

- `s:AnnotateDescribe(cl, client)`：`p4 describe -s <cl>` 解析出 user / origin_user /
  src_stream（`by X@`、`Origin: {'user': 'x'}`、`xxx from //src`）。
- `s:AnnotateRemapStream(depot, src_stream)`：替换 depot 路径第 5 段（index 4，因为开头
  `//` 产生两个空段）为源 stream 末段。
- `s:AnnotateDepotPath(file, client)`：`p4 files` 解析 depot 路径（剥 `#rev`）。
- `s:AnnotateFindContent(ann_out, content)`：内容精确匹配，返回 `[cl, lnum]` 列表。
- walk 循环最多 30 层；每层失败（无源 / 报错 / 内容 0 或多命中）都**静默降级**。
- walk 同时记录 `chain`（每层 `{cl, depot, origin}`），display 遍历 chain 分层输出到
  loclist：第一行直接 annotate 结果，后续行 `└─` 缩进 + 源 stream 逐层展开（对应
  Python 的 `chain`）。desc 只取第一行（丢弃 merge 的 Origin 块）并把换行压空格。
- 移除了原 `annotate -cI` integrate 单跳块，完全由 walk 接管（含 merge）。
- 配置 `g:vp4_annotate_cross_branch`（默认 1）、`g:vp4_annotate_bot_users`
  （默认 `['NGRBuild', 'NGRAutoMerge']`）。
- 命令 `:Vp4AnnotateLine [0|1]` 本次覆盖开关，方便 keymap 绑「强制不跨分支」。
- `g:_vp4_annotate_data` 新增 `depot_path` / `ref_rev` / `ref_lnum`；`Vp4AnnotateLineDiff`
  跨分支时用源路径 + `#head`。

### 踩坑

1. **`filelog -m N` 覆盖不到老 revision（根因）**：文件有 393 个 revision，branch CL 是
   #1（最老），`filelog -m 30` 根本不含它，`matchstr` 匹配不到 action。**已知 cl 时应
   用 `filelog -l -m 1 <file>@<cl>` 或 `describe -s <cl>` 精确查询，而非取最近 N 个。**

2. **源 revision 是范围**：`branch from //src#1,#14` 的 `#1,#14` 不是单个 `#rev`，
   `substitute(s, '#\d\+$', '', '')` 会剩 `#1,`。应剥 `#.*$`。

3. **Vim 正则 `\b` 不是单词边界**：是退格符。词尾用 `\>`，词首用 `\<`。

4. **Vim `split()` 默认丢弃空串**：`split('//a/b', '/')` 丢开头空串导致索引错位，remap
   必须 `split(path, '/', 1)`（keepempty=1）才能让 stream 落在 index 4，且 join 后保留
   `//` 前缀。

5. **`p4 describe` 对超大 branch CL 慢，`-m1` 是关键**：`describe -s <cl>` 会枚举该 CL 的
   全部 affected files，branch 几十万文件的 CL 要 ~10s。`-m1`（最多列 1 个文件）让服务端
   提前停止枚举（0.03s）。`-ztag`/`-F` 只改输出格式，服务端仍枚举全部文件，反而更慢
   （`-ztag` 展开每文件字段可达 31s / 千万行）。需要的是描述字段（`Branching from` /
   `Merge from` / `Origin`）不在 affected files 列表里，`-m1` 不影响它们。
