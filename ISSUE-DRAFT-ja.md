# タイトル

A child created by open(FH, '|-') cannot read its STDIN if the parent read STDIN to EOF first
（親が STDIN を EOF まで読んだ後 open(FH, '|-') で作った子プロセスは STDIN を読めない）

# 本文

## Description（説明）

自分の STDIN を最後まで読んだプロセスが `open(FH, '|-')` で書き込み
用の子プロセスを fork すると、子プロセスの STDIN は新しいパイプで
あるにも関わらず、何も読み込めません。fork より前に立った EOF の状態
がそのまま効いています。

この状態はディスクリプタではなく**ハンドル**に属しています。
`open(FH, '|-')` は子プロセスで fd 0 にパイプを dup2 しますが、STDIN
の PerlIO オブジェクトは fork を越えて継承されたものであり、EOF フラグ
もそのまま残ります。子プロセスで `STDIN->clearerr` を呼ぶだけで動くよう
になり、これが原因をそのフラグに特定します。レイヤースタックだけを触る
`binmode STDIN` では直りません。

これは退行ではありません。確認している限り 5.12 以来この挙動です。

## Steps to Reproduce（再現手順）

```perl
$_ = do { local $/; <STDIN> };          # 親が EOF まで読む
if (open(CHLD, '|-') == 0) {
    print <STDIN>;                      # 何も読めない
    exit;
}
print CHLD $_;
```

```
$ printf 'hello\nworld\n' | perl that.pl
$                                       # hello/world を期待
```

子プロセスの先頭に `STDIN->clearerr` を足すと、同じスクリプトが 2 行を
出力します。

## 動くもの、動かないもの

5.12.5 から 5.44.0 までの全リリースで測定
（[結果とワークフロー](https://github.com/kaz-utashiro/perl-stdin-eof-bench)）：

| 子プロセスで何をするか | 5.12.5 – 5.36.3 | 5.38.0 – 5.44.0 |
|---|---|---|
| 何もしない（STDIN を読むだけ） | FAIL | FAIL |
| `exec "cat"` | ok | ok |
| `STDIN->clearerr` | ok | ok |
| `open STDIN, '<&', 0` | ok | ok |
| `'\|-'` ではなく自前の `pipe` を使う | ok | ok |
| `scalar <STDIN> if eof STDIN` | ok | **FAIL** |
| 親がリストコンテキストで読む（子は何もしない） | ok | **FAIL** |

`exec` で動くのは、この状態がハンドルの性質だからです。プログラムが
置き換わればそれを持ち越すハンドルが残りません。perl 内で済ませる修正
は `clearerr` だけで足り、それが EOF フラグを原因として特定します。
レイヤースタックだけを触る `binmode STDIN` では何も起きません。

最後の 2 行が 5.38.0 で転ぶのは、80c1f1e45e が「失敗した readline が
ストリーム状態を解除する」挙動をやめたためです。これは意図的な変更
（#20060、#21240 で決着）なので退行として報告するつもりはなく、結果
として出口が `clearerr`、fdopen 相当の再オープン、自前の pipe の 3 つに
絞られたことだけを記しておきます。#21240 で古い EOF の解除手段として
挙げられている `clearerr` が本件を直すというのも、状態がどこに存在して
いるかの手がかりです。2014 年に「不思議」と書いた件もこれで片付きます。
リストコンテキストは失敗した読み込みで終わるので、入力を `@_` に読むのが
特別だったわけではなく、通常の配列でも同じです。

## Where this comes from（原因の所在）

util.c の `Perl_my_popen()` の子プロセス側は、ディスクリプタをシステム
レベルで差し替え、Perl レベルのハンドルには触りません：

```c
if (p[THIS] != (*mode == 'r')) {
    PerlLIO_dup2(p[THIS], *mode == 'r');
    PerlLIO_close(p[THIS]);
```

つまり STDIN は置き換えられていません。fork を越えてそのまま継承された
ハンドルの下で、パイプが fd 0 に dup2 されるだけで、バッファもフラグも
元のままです。同じ関数の数行下がそのことを明言しており、しかも帰結の
1 つを手作業で補正しています：

```c
#ifdef PERLIO_USING_CRLF
   /* Since we circumvent IO layers when we manipulate low-level
      filedescriptors directly, need to manually switch to the
      default, binary, low-level mode; see PerlIOBuf_open(). */
   PerlLIO_setmode((*mode == 'r'), O_BINARY);
#endif
```

古い EOF／エラー状態を解除するのも、同じ場所での同種の補正であり、
いま `STDIN->clearerr` が手作業でやっていることです。

（#24883 は似た症状 — 標準ハンドルがディスクリプタの差し替えを越えて
状態を保つ — を示しますが、経路は別です。あちらは perl が意図的に古い
PerlIO オブジェクトを退避して復帰させます。こちらにはそういう経路が
なく、ハンドルは一度も触られません。）

## Discussion（議論）

子プロセスの STDIN はパイプですが、それを読むハンドルは fork 以前から
継承されたものであり、そのハンドルが持つ EOF／エラー状態は新しい
ディスクリプタには無関係です。子プロセス側でそれを解除するのが自然に
見えますし、それがいま `STDIN->clearerr` が手作業でやっていることです。

少なくとも `open` の `'|-'` 形式のドキュメントに注記する価値はあると
思います。「子プロセスの STDIN はパイプになる」という素直な読み方から
は、fork 以前の状態がそれになお効いているとは思えないからです。

## Real-world impact（実世界での影響）

[App::Greple](https://metacpan.org/dist/App-Greple) で発見しました。
出力フィルタを設定すると、素朴な実装では入力ファイルの数だけフィルタ
プロセスが起動されます。マッチしたかどうかに関わらずです。したがって
マッチが判明してから初めてフィルタを起動する必要があり、それは fork
より前に入力を読むことを意味します。13,000 個の小さなファイル
（1 イベント 1 ファイルのカレンダー）があるディレクトリを検索するのは、
そうして初めて実用的になります。2014 年以来、回避策は fdopen 相当の
再オープンです。

「先に読んで、後で fork する」フィルタを書く人は誰でもこれに当たります。
しかも症状は「子プロセスが黙って何も出さない」なので、原因の手がかりが
まったくありません。

2014 年の記事（日本語）は今も残っています：
https://qiita.com/kaz-utashiro/items/80fc83e56e645f19e927

## Perl configuration（環境）

ubuntu-latest + shogo82148/actions-setup-perl のビルド
（5.12.5〜5.44.0）で測定。macOS/arm64 + Homebrew perl 5.44.0 でも再現。

perl -V の全文は英語版 (ISSUE-DRAFT.md) の `<details>` ブロックに
あります。
