# Vp4FilelogDiff 功能使用说明

## 新增功能

为 vim-vp4 插件添加了查看文件 revision 修改内容的功能。

## 使用方法

### 方法 1: 使用快捷键（推荐）

1. 打开一个已经在 Perforce 管理下的文件
2. 执行命令：`:Vp4Filelog`
3. 会自动打开 location list 窗口，显示该文件的所有 revision 历史
4. 在 location list 窗口中使用 `j`/`k` 键移动到想要查看的 revision
5. 按 `d` 键查看该 revision 相对于前一个 revision 的修改内容
6. 在 diff 窗口中按 `q` 键关闭

### 方法 2: 使用命令

1. 打开一个已经在 Perforce 管理下的文件
2. 执行命令：`:Vp4Filelog`
3. 在 location list 窗口中移动到想要查看的 revision
4. 执行命令：`:Vp4FilelogDiff`
5. 在 diff 窗口中按 `q` 键关闭

## 调试

如果遇到问题，可以启用调试模式：

```vim
:let g:perforce_debug = 1
```

然后再次尝试，会看到详细的调试信息。

## 注意事项

- 只有 revision #2 及以上的版本才能查看 diff（#1 没有前一个版本）
- 需要确保能够连接到 Perforce 服务器
- 使用 `p4 diff2` 命令生成 diff，需要相应的权限

## 实现细节

- 新增命令：`Vp4FilelogDiff`
- 在 location list 窗口中自动添加快捷键 `d`
- Diff 以 unified format 显示在新标签页中
- Diff 窗口包含有用的头部信息（文件路径、revision 号、changelist 描述）
