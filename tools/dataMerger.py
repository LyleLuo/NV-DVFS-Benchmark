import json
import pandas as pd
import argparse
import sys
import configparser


def main():
    """Main function."""
    parser = argparse.ArgumentParser()

    parser.add_argument('--ptx-csv', type=str, default='data/ptx.csv')
    parser.add_argument('--kernel-setting', type=str)
    parser.add_argument('--profile-csv', type=str)
    parser.add_argument('--output', type=str, default='data/data.csv')

    args = parser.parse_args()
    print(args)

    # Read GPU application settings
    cfg_name = 'configs/kernels/%s.cfg' % args.kernel_setting
    cf_ks = configparser.ConfigParser()
    cf_ks.read(cfg_name)
    benchmark_programs = cf_ks.sections()

    app_kernel = {}
    for app in benchmark_programs:
        app_kernel[app] = json.loads(cf_ks.get(app, 'kernels'))[0]

    ptx_stats = pd.read_csv(args.ptx_csv, header=0)
    profile_stats = pd.read_csv(args.profile_csv, header=0)

    target_ptx_stats = pd.DataFrame()
    for (app, kernel) in app_kernel.items():
        recs = ptx_stats[(ptx_stats.benchmark == app) & (ptx_stats['kernel'].str.contains(kernel))]
        print(app, kernel, len(recs))
        target_ptx_stats = target_ptx_stats.append(recs.iloc[0])

    target_ptx_stats = target_ptx_stats.reset_index()
    print(len(target_ptx_stats), len(profile_stats))

    join_stats = pd.merge(profile_stats, target_ptx_stats, how='left', on='benchmark')
    print(len(join_stats))
    print(join_stats.head())
    join_stats.to_csv(args.output, index=False)


if __name__ == '__main__':
    main()
