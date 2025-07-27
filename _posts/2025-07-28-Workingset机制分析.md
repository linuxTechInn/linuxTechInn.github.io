---
layout: post
title: workingset源码分析
date: 2025-07-28 00:46:40 
last_modified_at: 2025-07-28 00:46:40 
tags: [Linux, 内存]
author: Daniel
toc: true
description: 关于workingset源码分析的文章
---
# Workingset机制

## 什么是workingset机制？

--待补充

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

