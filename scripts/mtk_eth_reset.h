/* SPDX-License-Identifier: GPL-2.0
 *
 * Copyright (c) 2022 MediaTek Inc.
 * Author: Henry Yen <henry.yen@mediatek.com>
 *
 * Minimal mtk_eth_reset.h for MTK NPU compilation.
 * The NPU (kmod-mtk_npu) only needs these notifier event constants.
 */

#ifndef MTK_ETH_RESET_H
#define MTK_ETH_RESET_H

/* Frame Engine Reset FSM */
#define MTK_FE_START_RESET		(0x2000)
#define MTK_FE_RESET_DONE		(0x2001)
#define MTK_WIFI_RESET_DONE		(0x2002)
#define MTK_WIFI_CHIP_ONLINE		(0x2003)
#define MTK_WIFI_CHIP_OFFLINE		(0x2004)
#define MTK_FE_STOP_TRAFFIC		(0x2005)
#define MTK_FE_STOP_TRAFFIC_DONE	(0x2006)
#define MTK_FE_START_TRAFFIC		(0x2007)
#define MTK_FE_STOP_TRAFFIC_DONE_FAIL	(0x2008)
#define MTK_FE_START_RESET_INIT		(0x2009)
#define MTK_WIFI_L1SER_DONE		(0x200a)
#define MTK_TOPS_DUMP_DONE		(0x3001)
#define MTK_FE_RESET_NAT_DONE		(0x4001)

#endif		/* MTK_ETH_RESET_H */
