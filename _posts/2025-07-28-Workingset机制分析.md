---
layout: post
title: workingset机制分析
date: 2025-07-28 00:46:40 
last_modified_at: 2025-07-28 00:46:40 
tags: [Linux, 内存]
author: Daniel
toc: true
description: 关于workingset源码分析的文章
---
# Workingset机制

## 什么是workingset机制？

什么是workingset？workingset其实就是一种内存页冷热识别机制。它定义了抖动和访问距离的概念，如果访问距离小于所有内存，则认为这样的page是抖动的，这些page就会被promoted。

以下内容基于workingset.c注释中的内容整理

#### 不翻译的概念

有些概念我不进行重新翻译，而是使用注释使用的单词，这样方便在阅读文章之后，能够更加连贯的阅读代码

promoted  ：将page从inactive list移动到active list

demoted	:  将page从active list移动到inactive list

active list   :  活跃的链表，不能被回收，上面的page需要移动到inactive list才能被回收

inactive list：满足一定条件就可以被回收

#### 隐含的假设

比如memcg只有一个

#### active list 和inactive list的基本工作模式

1、新发生缺页异常的页面会从inactive list的头部加入，而页面回收则从inactive list的尾部开始扫描

2、在inactive list中多次被访问的页面会被promoted到active list ，从而避免被回收

3、当active list过大时，active page则会被demoted到inactive list中

#### 访问频率和缺页距离的由来和定义

##### 抖动的定义

如果一个inactive list的page被频繁使用，但每次在它被promoted之前，它就被回收了，这种现象就是抖动。

##### 讨论以下三种情况

1、如果抖动页的平均的访问距离大于当前内存的大小，这种抖动是因为内存不足导致，这是没有办法处理的。

2、如果面对平均访问距离大于inactive list，但是却小于内存大小的情况。如果不是active page挤占了内存，工作集是完全能够处理这种抖动的。

3、考虑到跟踪每个页面的访问频率的代价过于高昂，通过检测和估计inactive list的抖动情况，将抖动的页面提升到active list当中和活跃的page竞争。

##### 估算inactive page的访问频率

如何估算inactive page的访问频率？

首先，系统中的inactive page的访问行为可以归结为以下两种情况。

1、假如当前的内存大小是固定的情况，如果一个page被第一次访问，也就是第一次处理缺页，它会被加到inactive list当中，当前inactive list上的page都会往后挪一个单位的距离，最后一个page就被回收了。

2、假如当前的内存大小是固定的情况，如果一个page被访问第二次，它会被promoted到active list当中，此时，inactive list的槽位就会少一个，同时，原先在这个page之后的页都会向尾部移动一个槽位的距离。

以及上述情况

1、所有的回收（情况1）和所有的promoted（情况2）的总和就可以用来表示最小的inactive page的访问次数，在代码中使用lruvec->nonresident_age记录这个值，6.12内核代码中使用workingset_age_nonresident(lruvec, folio_nr_pages(folio))函数完成这个过程。

2、将一个inactive page移动n个槽位需要至少n次inactive page的访问。

继续推导，可以得出以下两个的重要结论：

1、当一个page最后被evicted的时候，至少有inactive list大小的inactive page访问次数。

2、可以将page被回收的时和page被重新读入时的inactive page的访问次数的差值定义成refault distance。

基于上述概念，因此定义访问距离为 NR_inactive + (R - E) ,其中，R是page 被回收时的inactive page访问次数，E时重新缺页时的inactive page访问次数。它的含义指的是page从第一次缺页到被回收之后重新缺页，这段时间的inactive page访问次数总共，如果这个值大于所有的内存，则说明这种缺页是无法处理的，如果这个值小于所有的内存，则说明这种缺页是不应该发生的。因此，缺页距离小于所有内存的时候，这个page会被定义成抖动的，也就是NR_inactive + (R - E) <= NR_inactive + NR_active，由于有匿名页和文件页，因此实际的抖动可以被定义成：

```
文件页:NR_inactive_file + (R - E) <= NR_inactive_file + NR_active_file + NR_inactive_anon + NR_active_anon
匿名页:NR_inactive_anon + (R - E) <= NR_inactive_anon + NR_active_anon + NR_inactive_file + NR_active_file
可以被简化为
(R - E) <= NR_active_file + NR_inactive_anon + NR_active_anon
(R - E) <= NR_active_anon + NR_inactive_file + NR_active_file
```



## 主要代码梳理 -- 基于传统的LRU逻辑分析

#### shadow的值

用于保存memcgid、node_id、workingset标志、lruvec->nonresident_age >> bucket_order信息的值，这是一个unsigned long 类型的数字。这个数字各个位上依次保存的信息如下所示

```
||<--EVICTION_SHIFT-->||<--MEM_CGROUP_ID_SHIFT-->||<--NODES_SHIFT-->||<--WORKINGSET_SHIFT-->||
```

EVICTION_SHIFT保存的是lruvec->nonresident_age >> bucket_order的值

MEM_CGROUP_ID_SHIFT保存的是memcg_id的值

NODES_SHIFT保存的是node_id的值

WORKINGSET_SHIFT保存的是workingset的值

lruvec->nonresident_age 记录的是一个memcg的被回收次数与refault次数

#### pack_shadow

将shadow信息保存到adress_space->i_pages当中，这是一个xarray，访问的索引是文件内容相对于地址空间的偏移量，对于匿名页，这个文件就是一个被抽象的swap文件，当一个匿名页被回收的时候，他会先分配一个slot，这个slot就是被回收页的在swap空间的偏移量，代码上可以通过pgoff_t idx = swap_cache_index(entry)获取这个索引。

#### unpack_shadow

将一个被回收页的shadow的内容重新读入

#### workingset_test_recent

检查缺页的页是否是最近回收的，判断是否是最近的标准是refault_distance 的距离小于workingset_size
refault_distance = (refault - eviction)

eviction 是page被回收时lruvec->nonresident_age左移 bucket_order位，又右移bucket_order位的值，也就是将bucket_order位上的值置零的lruvec->nonresident_age。

refault 则是page被重新缺页时lruvec->nonresident_age的值

workingset_size
对于文件页来说，workingset_size== 活跃的文件页+活跃的匿名页+非活跃的匿名页

对于匿名页来说，workingset_size ==活跃的文件页+非活跃的文件页+活跃的匿名页

这是workingset的核心函数，这个函数返回true的时候，重新缺页的page就会被标记成active，它就会被放到active list当中

#### workingset_refault

1、记录workingset_refault的次数

2、记录lru_note_cost_refault的值

3、标记一个page是否属于workingset，是否属于workingset在回收的时候就已经确定了

#### workingset标记

shrink_active_list过程中，如果一个page要被de-active，也就是移动到inactive list当中，这个时候这个page就会被标记为workingset

