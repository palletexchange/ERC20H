import { mine } from '@nomicfoundation/hardhat-network-helpers'
import '@openzeppelin/hardhat-upgrades'
import { expect } from 'chai'
import hre, { ethers, upgrades } from 'hardhat'

import { Marketplace, MarketplaceAuxiliary, MarketplaceUserSettings } from '../typechain-types'

describe('ERC20H', () => {
  async function deployFixtures() {
    const [owner, user1, user2, user3, user4] = await hre.ethers.getSigners()

    const ERC20H = await ethers.getContractFactory('ERC20HMintable')
    const ft = await ERC20H.deploy(owner)

    const ERC20HMirror = await ethers.getContractFactory('ERC20HMintableMirror')
    const nft = await ERC20HMirror.deploy(owner, ft)

    await ft.setMirror(nft)

    return {
      owner,
      user1,
      user2,
      user3,
      user4,
      ft,
      nft,
    }
  }

  async function deployFixturesWithTiers() {
    const fixtures = await deployFixtures()
    const { nft } = fixtures

    await nft.addTiers([
      {
        units: BigInt(10_000),
        maxSupply: 10,
        uri: 'ipfs://1234567890/',
      },
      {
        units: BigInt(1_000),
        maxSupply: 2,
        uri: 'ipfs://abcdefghijklmnopqrstuvwxyz/',
      },
      {
        units: BigInt(1_000),
        maxSupply: 20,
        uri: 'ipfs://a1b2c3d4e5g6h7i8j9k0/',
      },
    ])

    return fixtures
  }

  async function deployFixturesWithActiveTiers() {
    const fixtures = await deployFixturesWithTiers()
    const { nft } = fixtures

    await nft.setActiveTiers([0, 1, 2])

    return fixtures
  }

  describe('init', () => {
    it('addTiers() & removeTier()', async () => {
      const { owner, ft, nft } = await deployFixtures()

      expect((await nft.getTier(0)).units).to.eq(0)
      expect((await nft.getTier(1)).units).to.eq(0)

      await nft.addTiers([
        {
          units: BigInt(10_000),
          maxSupply: 100,
          uri: 'ipfs://1234567890',
        },
        {
          units: BigInt(1_000),
          maxSupply: 200,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
      ])

      const tier0 = await nft.getTier(0)
      expect(tier0.tierId).to.eq(0)
      expect(tier0.active).to.false
      expect(tier0.nextTokenIdSuffix).to.eq(0)
      expect(tier0.totalSupply).to.eq(0)
      expect(tier0.maxSupply).to.eq(100n)
      expect(tier0.units).to.eq(10_000n)
      expect(tier0.uri).to.eq('ipfs://1234567890')
      const tier1 = await nft.getTier(1)
      expect(tier1.tierId).to.eq(1)
      expect(tier1.active).to.false
      expect(tier1.nextTokenIdSuffix).to.eq(0)
      expect(tier1.totalSupply).to.eq(0)
      expect(tier1.maxSupply).to.eq(200n)
      expect(tier1.units).to.eq(1_000n)
      expect(tier1.uri).to.eq('ipfs://abcdefghijklmnopqrstuvwxyz')

      await nft.removeTier(0)
      await nft.removeTier(1)

      expect((await nft.getTier(0)).units).to.eq(0)
      expect((await nft.getTier(1)).units).to.eq(0)
    })

    it('setActiveTiers() & getActiveTiers()', async () => {
      const { owner, ft, nft } = await deployFixturesWithTiers()

      // baseline: check that active tiers is empty
      expect(await nft.getActiveTiers()).to.be.an('array').that.is.empty
      let tier0 = await nft.getTier(0)
      expect(tier0.active).to.false
      let tier1 = await nft.getTier(1)
      expect(tier1.active).to.false
      let tier2 = await nft.getTier(2)
      expect(tier2.active).to.false

      // cannot set a tier that does not exist
      await expect(nft.setActiveTiers([100])).to.be.revertedWithCustomError(nft, 'ERC20HMirrorTierDoesNotExist')

      // active tiers must be in descending order of units
      await expect(nft.setActiveTiers([1, 0])).to.be.revertedWithCustomError(
        nft,
        'ERC20HMirrorActiveTiersMustBeInDescendingOrder',
      )

      // active tiers must not have repeats
      await expect(nft.setActiveTiers([0, 1, 1])).to.be.revertedWithCustomError(nft, 'ERC20HMirrorDuplicateActiveTier')

      // can set active tiers with same units
      await nft.setActiveTiers([0, 1, 2])
      tier0 = await nft.getTier(0)
      expect(tier0.active).to.true
      tier1 = await nft.getTier(1)
      expect(tier1.active).to.true
      tier2 = await nft.getTier(2)
      expect(tier2.active).to.true
      expect(`${await nft.getActiveTiers()}`).to.eq(`${[0n, 1n, 2n]}`)

      // can set active tiers to be empty
      await nft.setActiveTiers([])
      tier0 = await nft.getTier(0)
      expect(tier0.active).to.false
      tier1 = await nft.getTier(1)
      expect(tier1.active).to.false
      tier2 = await nft.getTier(2)
      expect(tier2.active).to.false
      expect(`${await nft.getActiveTiers()}`).to.eq(`${[]}`)
    })

    it('add a lot of tiers', async () => {
      const { owner, ft, nft } = await deployFixturesWithTiers()

      const numTiers = 200
      const newTiers: { units: bigint; maxSupply: bigint; uri: string }[] = []
      const activeTiers: number[] = []
      for (let i = 0; i < numTiers; i++) {
        newTiers.push({
          units: BigInt(i + 1),
          maxSupply: 100n,
          uri: `https://static.drip.trade/hyperlaunch/hypers/metadata/${i}.json`,
        })
        activeTiers.push(numTiers + 2 - i)
      }
      await nft.addTiers(newTiers)
      await nft.setActiveTiers(activeTiers)

      const tiers = await nft.getActiveTiers()
      await expect(tiers.length).to.eq(numTiers)
    })
  })

  describe('getMintableNumberOfTokens() & getMintableTokenIds()', () => {
    it('Returns 0 when no tiers', async () => {
      const { owner, ft, nft } = await deployFixtures()

      const [numTokens, fundsNeeded] = await nft.getMintableNumberOfTokens(20_000n)
      expect(numTokens).to.eq(0)
      expect(fundsNeeded).to.eq(0)
    })

    it('Returns 0 when no active tiers', async () => {
      const { owner, ft, nft } = await deployFixturesWithTiers()

      const [numTokens, fundsNeeded] = await nft.getMintableNumberOfTokens(20_000n)
      expect(numTokens).to.eq(0)
      expect(fundsNeeded).to.eq(0)
    })

    it('Returns 0 when not enough funds', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()

      const [numTokens, fundsNeeded] = await nft.getMintableNumberOfTokens(200n)
      expect(numTokens).to.eq(0)
      expect(fundsNeeded).to.eq(0)
    })

    it('Returns 2 when enough funds for 2 NFTs in the same tier', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()

      const [numTokens, fundsNeeded] = await nft.getMintableNumberOfTokens(20_100n)
      expect(numTokens).to.eq(2)
      expect(fundsNeeded).to.eq(20_000n) // there is 100n left over
    })

    it('Returns 2 when enough funds for 2 NFTs in different tiers', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()

      const [numTokens, fundsNeeded] = await nft.getMintableNumberOfTokens(11_100n)
      expect(numTokens).to.eq(2)
      expect(fundsNeeded).to.eq(11_000n) // there is 100n left over
    })

    it('Respects the maxSupply of each tier', async () => {
      const { owner, ft, nft } = await deployFixtures()

      await nft.addTiers([
        {
          units: BigInt(100),
          maxSupply: 2,
          uri: 'ipfs://1234567890',
        },
        {
          units: BigInt(10),
          maxSupply: 2,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
      ])
      await nft.setActiveTiers([0, 1])

      const [numTokens, fundsNeeded] = await nft.getMintableNumberOfTokens(11_100n)
      expect(numTokens).to.eq(4)
      expect(fundsNeeded).to.eq(220n)
    })

    it('Skips over tiers when not enough backing', async () => {
      const { owner, ft, nft } = await deployFixtures()

      await nft.addTiers([
        {
          units: BigInt(100),
          maxSupply: 2,
          uri: 'ipfs://1234567890',
        },
        {
          units: BigInt(70),
          maxSupply: 2,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
        {
          units: BigInt(10),
          maxSupply: 100,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
      ])
      await nft.setActiveTiers([0, 1, 2])

      const [numTokens, fundsNeeded] = await nft.getMintableNumberOfTokens(150n)
      expect(numTokens).to.eq(6)
      expect(fundsNeeded).to.eq(150n)
    })

    it('Grabbing 0 mintable tokens will return 0 token ids', async () => {
      const { owner, ft, nft } = await deployFixtures()

      await nft.addTiers([
        {
          units: BigInt(100),
          maxSupply: 2,
          uri: 'ipfs://1234567890',
        },
        {
          units: BigInt(10),
          maxSupply: 2,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
      ])
      await nft.setActiveTiers([0, 1])

      const tokenIds = await nft.getMintableTokenIds(0, 100_000n)
      expect(tokenIds).to.be.an('array').that.is.empty
    })

    it('Grabbing 100 mintable tokens will return all possible token ids', async () => {
      const { owner, ft, nft } = await deployFixtures()

      await nft.addTiers([
        {
          units: BigInt(100),
          maxSupply: 2,
          uri: 'ipfs://1234567890',
        },
        {
          units: BigInt(10),
          maxSupply: 2,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
      ])
      await nft.setActiveTiers([0, 1])

      const tokenIds = await nft.getMintableTokenIds(100, 100_000n)
      expect(tokenIds.length).to.eq(4)
      // Note: tokenId = <tierId><nextTokenIdSuffix>
      expect(tokenIds[0]).to.eq(BigInt(0))
      expect(tokenIds[1]).to.eq(BigInt(1))
      expect(tokenIds[2]).to.eq((BigInt(1) << BigInt(32)) + BigInt(0))
      expect(tokenIds[3]).to.eq((BigInt(1) << BigInt(32)) + BigInt(1))
    })

    it('Token ids limited by funds', async () => {
      const { owner, ft, nft } = await deployFixtures()

      await nft.addTiers([
        {
          units: BigInt(100),
          maxSupply: 2,
          uri: 'ipfs://1234567890',
        },
        {
          units: BigInt(10),
          maxSupply: 2,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
      ])
      await nft.setActiveTiers([0, 1])

      const tokenIds = await nft.getMintableTokenIds(100, 111n)
      expect(tokenIds.length).to.eq(2)
      // Note: tokenId = <tierId><nextTokenIdSuffix>
      expect(tokenIds[0]).to.eq(BigInt(0))
      expect(tokenIds[1]).to.eq((BigInt(1) << BigInt(32)) + BigInt(0))
    })

    it('Token ids limited by numTokens', async () => {
      const { owner, ft, nft } = await deployFixtures()

      await nft.addTiers([
        {
          units: BigInt(100),
          maxSupply: 5,
          uri: 'ipfs://1234567890',
        },
        {
          units: BigInt(90),
          maxSupply: 5,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
        {
          units: BigInt(10),
          maxSupply: 5,
          uri: 'ipfs://abcdefghijklmnopqrstuvwxyz',
        },
      ])
      await nft.setActiveTiers([0, 1, 2])

      const tokenIds = await nft.getMintableTokenIds(5, 350n)
      expect(tokenIds.length).to.eq(5)
      // Note: tokenId = <tierId><nextTokenIdSuffix>
      expect(tokenIds[0]).to.eq(BigInt(0))
      expect(tokenIds[1]).to.eq(BigInt(1))
      expect(tokenIds[2]).to.eq(BigInt(2))
      expect(tokenIds[3]).to.eq((BigInt(2) << BigInt(32)) + BigInt(0))
      expect(tokenIds[4]).to.eq((BigInt(2) << BigInt(32)) + BigInt(1))
    })
  })

  describe('Locking and bonding behavior', () => {
    it('Cannot bond without ERC20H balance', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()

      const tokenIds = await nft.getMintableTokenIds(1, 10_000n)
      expect(tokenIds.length).to.eq(1)
      expect(tokenIds[0]).to.eq(BigInt(0))

      await expect(nft.bond(owner, tokenIds[0])).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnbondedBalance')
    })

    it('Cannot bond without locked ERC20H balance', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.mint(owner, 10_000n)

      const tokenIds = await nft.getMintableTokenIds(1, 10_000n)
      expect(tokenIds.length).to.eq(1)
      expect(tokenIds[0]).to.eq(BigInt(0))

      await expect(nft.bond(owner, tokenIds[0])).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnbondedBalance')
    })

    it('Bonds with locked ERC20H balance', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.mint(owner, 10_000n)
      await ft.lockOnly(10_000n)

      const [lockedStart, bondedStart, awaitingUnlockStart] = await ft.lockedBalancesOf(owner)
      expect(lockedStart).to.eq(10_000n)
      expect(bondedStart).to.eq(0)
      expect(awaitingUnlockStart).to.eq(0)

      await nft.bond(owner, 0n)

      const [lockedEnd, bondedEnd, awaitingUnlockEnd] = await ft.lockedBalancesOf(owner)
      expect(lockedEnd).to.eq(10_000n)
      expect(bondedEnd).to.eq(10_000n)
      expect(awaitingUnlockEnd).to.eq(0)

      expect(await nft.balanceOf(owner)).to.eq(1)
      expect(await nft.ownerOf(0n)).to.eq(await owner.getAddress())
      expect(await nft.tokenURI(0n)).to.eq('ipfs://1234567890/0')
    })

    it('lock()', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()

      await ft.mint(owner, 10_000n)
      const balance = await ft.balanceOf(owner)
      await expect(balance).to.eq(10_000n)

      await ft.lock(10_000n)
      const [locked, bonded, awaitingUnlock] = await ft.lockedBalancesOf(owner)
      await expect(locked).to.eq(10_000n)
      await expect(bonded).to.eq(10_000n)
      await expect(awaitingUnlock).to.eq(0n)

      expect(await nft.balanceOf(owner)).to.eq(1)
      expect(await nft.ownerOf(0n)).to.eq(await owner.getAddress())
      expect(await nft.tokenURI(0n)).to.eq('ipfs://1234567890/0')
    })

    it('lock() with unbonded leftovers', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()

      await ft.mint(owner, 20_000n)
      const balance = await ft.balanceOf(owner)
      await expect(balance).to.eq(20_000n)

      await ft.lock(10_500n)
      const [locked, bonded, awaitingUnlock] = await ft.lockedBalancesOf(owner)
      await expect(locked).to.eq(10_500n)
      await expect(bonded).to.eq(10_000n)
      await expect(awaitingUnlock).to.eq(0n)

      expect(await nft.balanceOf(owner)).to.eq(1)
      expect(await nft.ownerOf(0n)).to.eq(await owner.getAddress())
      expect(await nft.tokenURI(0n)).to.eq('ipfs://1234567890/0')
    })

    it('lock() to mint many tokens', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      const ownerAddress = await owner.getAddress()

      await ft.mint(owner, 200_000n)
      const balance = await ft.balanceOf(owner)
      await expect(balance).to.eq(200_000n)

      await ft.lock(200_000n)
      const [locked, bonded, awaitingUnlock] = await ft.lockedBalancesOf(owner)
      await expect(locked).to.eq(200_000n)
      await expect(bonded).to.eq(122_000n)
      await expect(awaitingUnlock).to.eq(0n)

      expect(await nft.balanceOf(owner)).to.eq(32)
      for (let i = 0; i < 10; i++) {
        const tid = (0n << 32n) + BigInt(i)
        expect(await nft.ownerOf(tid)).to.eq(ownerAddress)
        expect(await nft.tokenURI(tid)).to.eq(`ipfs://1234567890/${i}`)
      }
      for (let i = 0; i < 2; i++) {
        const tid = (1n << 32n) + BigInt(i)
        expect(await nft.ownerOf(tid)).to.eq(ownerAddress)
        expect(await nft.tokenURI(tid)).to.eq(`ipfs://abcdefghijklmnopqrstuvwxyz/${i}`)
      }
      for (let i = 0; i < 20; i++) {
        const tid = (2n << 32n) + BigInt(i)
        expect(await nft.ownerOf(tid)).to.eq(ownerAddress)
        expect(await nft.tokenURI(tid)).to.eq(`ipfs://a1b2c3d4e5g6h7i8j9k0/${i}`)
      }
    })
  })

  describe('Unlocking and unbonding behavior', () => {
    it('Cannot unlock without ERC20H balance', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()

      await expect(ft.unlock(10_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientLockedBalance')
    })

    it('Cannot unlock without locked ERC20H balance', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.mint(owner, 10_000n)

      await expect(ft.unlock(10_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientLockedBalance')
    })

    it('unlock()', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.mint(owner, 10_000n)
      await ft.lockOnly(10_000n)

      const [lockedStart, bondedStart, awaitingUnlockStart] = await ft.lockedBalancesOf(owner)
      expect(lockedStart).to.eq(10_000n)
      expect(bondedStart).to.eq(0)
      expect(awaitingUnlockStart).to.eq(0)

      await ft.unlock(1_000n)

      const [lockedEnd, bondedEnd, awaitingUnlockEnd] = await ft.lockedBalancesOf(owner)
      expect(lockedEnd).to.eq(9_000n)
      expect(bondedEnd).to.eq(0)
      expect(awaitingUnlockEnd).to.eq(0)

      // releasing does nothing
      await ft.release(100n, ethers.Typed.overrides({}))

      const [lockedEnd2, bondedEnd2, awaitingUnlockEnd2] = await ft.lockedBalancesOf(owner)
      expect(lockedEnd2).to.eq(9_000n)
      expect(bondedEnd2).to.eq(0)
      expect(awaitingUnlockEnd2).to.eq(0)
    })

    it('unlock() with cooldown', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.setUnlockCooldown(1000n)
      await ft.mint(owner, 10_000n)

      await ft.lockOnly(10_000n)

      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      expect(locked0).to.eq(10_000n)
      expect(bonded0).to.eq(0)
      expect(awaitingUnlock0).to.eq(0)

      await ft.unlock(1_000n) // unlocks tranche 1
      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(owner)
      expect(locked1).to.eq(10_000n)
      expect(bonded1).to.eq(0)
      expect(awaitingUnlock1).to.eq(1_000n)

      // releasing before cooldown ends does nothing
      await ft.release(1_000n, ethers.Typed.overrides({}))
      const [locked2, bonded2, awaitingUnlock2] = await ft.lockedBalancesOf(owner)
      expect(locked2).to.eq(10_000n)
      expect(bonded2).to.eq(0)
      expect(awaitingUnlock2).to.eq(1_000n)

      await mine(100)

      // releasing before cooldown ends does nothing
      await ft.release(1_000n, ethers.Typed.overrides({}))
      const [locked3, bonded3, awaitingUnlock3] = await ft.lockedBalancesOf(owner)
      expect(locked3).to.eq(10_000n)
      expect(bonded3).to.eq(0)
      expect(awaitingUnlock3).to.eq(1_000n)

      // unlock another tranche before the previous tranche has ended
      await ft.unlock(2_000n) // unlocks tranche 2
      const [locked4, bonded4, awaitingUnlock4] = await ft.lockedBalancesOf(owner)
      expect(locked4).to.eq(10_000n)
      expect(bonded4).to.eq(0)
      expect(awaitingUnlock4).to.eq(3_000n)

      await mine(500)

      // unlock another 2 tranches before the previous tranches have ended
      await ft.unlock(700n) // unlocks tranche 3
      await ft.unlock(800n) // unlocks tranche 4
      const [locked5, bonded5, awaitingUnlock5] = await ft.lockedBalancesOf(owner)
      expect(locked5).to.eq(10_000n)
      expect(bonded5).to.eq(0)
      expect(awaitingUnlock5).to.eq(4_500n)

      await mine(400) // first tranche should be ready

      // should only be able to release the first tranche
      await ft.release(100n, ethers.Typed.overrides({})) // releases tranche 1
      const [locked6, bonded6, awaitingUnlock6] = await ft.lockedBalancesOf(owner)
      expect(locked6).to.eq(9_000n)
      expect(bonded6).to.eq(0)
      expect(awaitingUnlock6).to.eq(3_500n)
      expect(await ft.balanceOf(owner)).to.eq(10_000n)

      await mine(1000) // next 2 tranches should be ready

      // release only 1 tranche, leaving 2 more tranches
      await ft.release(1n, ethers.Typed.overrides({})) // releases tranche 2
      const [locked7, bonded7, awaitingUnlock7] = await ft.lockedBalancesOf(owner)
      expect(locked7).to.eq(7_000n)
      expect(bonded7).to.eq(0)
      expect(awaitingUnlock7).to.eq(1_500n)
      expect(await ft.balanceOf(owner)).to.eq(10_000n)

      await ft.release(10n, ethers.Typed.overrides({})) // releases tranches 2 and 3
      const [locked8, bonded8, awaitingUnlock8] = await ft.lockedBalancesOf(owner)
      expect(locked8).to.eq(5_500n)
      expect(bonded8).to.eq(0)
      expect(awaitingUnlock8).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(10_000n)
    })

    it('unlock() + release() many tranches', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 200_000n)

      await ft.lockOnly(200_000n)

      // unlock 100 tranches
      for (let i = 0; i < 100; i++) {
        await ft.unlock(1_000n)
      }

      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      expect(locked0).to.eq(200_000n)
      expect(bonded0).to.eq(0)
      expect(awaitingUnlock0).to.eq(100_000n)

      await mine(100n)
      await ft.release(ethers.Typed.overrides({}))

      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(owner)
      expect(locked1).to.eq(100_000n)
      expect(bonded1).to.eq(0)
      expect(awaitingUnlock1).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(200_000n)

      // unlock another 100 tranches
      for (let i = 0; i < 50; i++) {
        await ft.unlock(2_000n)
      }

      const [locked2, bonded2, awaitingUnlock2] = await ft.lockedBalancesOf(owner)
      expect(locked2).to.eq(100_000n)
      expect(bonded2).to.eq(0)
      expect(awaitingUnlock2).to.eq(100_000n)

      await mine(100n)
      await ft.release(ethers.Typed.overrides({}))

      const [locked3, bonded3, awaitingUnlock3] = await ft.lockedBalancesOf(owner)
      expect(locked3).to.eq(0)
      expect(bonded3).to.eq(0)
      expect(awaitingUnlock3).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(200_000n)
    })

    it('unlock() while there are still tokens awaiting unlock', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 200_000n)

      await ft.lockOnly(200_000n)
      await ft.unlock(1_000n)
      await ft.unlock(1_000n)
      await ft.unlock(1_000n)
      await ft.unlock(1_000n)
      await ft.unlock(1_000n)

      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      expect(locked0).to.eq(200_000n)
      expect(bonded0).to.eq(0)
      expect(awaitingUnlock0).to.eq(5_000n)

      await mine(100n)
      await ft.release(4n, ethers.Typed.overrides({}))

      await ft.unlock(1_000n)
      await ft.unlock(1_000n)
      await ft.unlock(1_000n)
      await ft.unlock(1_000n)

      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(owner)
      expect(locked1).to.eq(196_000n)
      expect(bonded1).to.eq(0)
      expect(awaitingUnlock1).to.eq(5_000n)
      expect(await ft.balanceOf(owner)).to.eq(200_000n)

      await mine(100n)
      await ft.release(ethers.Typed.overrides({}))

      const [locked2, bonded2, awaitingUnlock2] = await ft.lockedBalancesOf(owner)
      expect(locked2).to.eq(191_000n)
      expect(bonded2).to.eq(0)
      expect(awaitingUnlock2).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(200_000n)
    })

    it('Cannot lock tokens that are awaiting unlock', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()

      await ft.mint(owner, 10_000n)

      const balance = await ft.balanceOf(owner)
      await expect(balance).to.eq(10_000n)

      await ft.lock(10_000n)
      const [locked, bonded, awaitingUnlock] = await ft.lockedBalancesOf(owner)
      await expect(locked).to.eq(10_000n)
      await expect(bonded).to.eq(10_000n)
      await expect(awaitingUnlock).to.eq(0n)

      expect(await nft.balanceOf(owner)).to.eq(1)
      expect(await nft.ownerOf(0n)).to.eq(await owner.getAddress())
      expect(await nft.tokenURI(0n)).to.eq('ipfs://1234567890/0')
    })

    it('unlock() affects how many tokens can be bonded', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 20_000n)

      await ft.lockOnly(10_000n)
      await ft.unlock(5_000n)
      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      await expect(locked0).to.eq(10_000n)
      await expect(bonded0).to.eq(0)
      await expect(awaitingUnlock0).to.eq(5_000n)

      // lock up additional 10000 tokens
      await expect(ft.lock(15_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnlockedBalance')

      // lock up an additional 1000 tokens
      await ft.lock(1_000n)
      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(owner)
      await expect(locked1).to.eq(11_000n)
      await expect(bonded1).to.eq(6_000n)
      await expect(awaitingUnlock1).to.eq(5_000n)
      expect(await nft.balanceOf(owner)).to.eq(6)

      // locking 0 will bond all unbonded locked tokens
      await ft.lockOnly(2_000n)
      const [locked2, bonded2, awaitingUnlock2] = await ft.lockedBalancesOf(owner)
      await expect(locked2).to.eq(13_000n)
      await expect(bonded2).to.eq(6_000n)
      await expect(awaitingUnlock2).to.eq(5_000n)
      expect(await nft.balanceOf(owner)).to.eq(6)
      await ft.lock(0n)
      const [locked3, bonded3, awaitingUnlock3] = await ft.lockedBalancesOf(owner)
      await expect(locked3).to.eq(13_000n)
      await expect(bonded3).to.eq(8_000n)
      await expect(awaitingUnlock3).to.eq(5_000n)
      expect(await nft.balanceOf(owner)).to.eq(8)
    })

    it('Cannot unlock tokens that are locked', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 30_000n)

      const balance = await ft.balanceOf(owner)
      await expect(balance).to.eq(30_000n)

      await ft.lock(10_100n)
      await ft.unlock(60n)
      const [locked, bonded, awaitingUnlock] = await ft.lockedBalancesOf(owner)
      await expect(locked).to.eq(10_100n)
      await expect(bonded).to.eq(10_000n)
      await expect(awaitingUnlock).to.eq(60n)

      await expect(ft.unlock(11_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientLockedBalance')

      await expect(ft.unlock(9_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnbondedBalance')

      await expect(ft.unlock(55n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnbondedBalance')
    })

    it('Unbonding NFT releases tokens without cooldown', async () => {
      const { owner, ft, nft } = await deployFixturesWithActiveTiers()
      const ownerAddress = await owner.getAddress()

      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 20_000n)

      await ft.lock(10_000n)
      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      await expect(locked0).to.eq(10_000n)
      await expect(bonded0).to.eq(10_000n)
      await expect(awaitingUnlock0).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(20_000n)
      expect(await nft.balanceOf(owner)).to.eq(1)
      expect(await nft.ownerOf(0n)).to.eq(ownerAddress)

      // unbond token id 0
      await nft.unbond(0n)

      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(owner)
      await expect(locked1).to.eq(0)
      await expect(bonded1).to.eq(0)
      await expect(awaitingUnlock1).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(20_000n)
      expect(await nft.balanceOf(owner)).to.eq(0)
      await expect(nft.ownerOf(0n)).to.be.revertedWithCustomError(nft, 'ERC721NonexistentToken')
    })

    it('Can only unbond another users tokens with approval', async () => {
      const { owner, user1, ft, nft } = await deployFixturesWithActiveTiers()
      const ownerAddress = await owner.getAddress()

      await ft.mint(owner, 20_000n)
      await ft.lock(20_000n)

      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      await expect(locked0).to.eq(20_000n)
      await expect(bonded0).to.eq(20_000n)
      await expect(awaitingUnlock0).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(20_000n)
      expect(await nft.balanceOf(owner)).to.eq(2)

      await expect(nft.connect(user1).unbond(2n)).to.be.revertedWithCustomError(nft, 'ERC721NonexistentToken')

      await expect(nft.connect(user1).unbond(0n)).to.be.revertedWithCustomError(nft, 'ERC721InsufficientApproval')

      await nft.approve(user1, 0n)
      await nft.connect(user1).unbond(0n)

      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(owner)
      await expect(locked1).to.eq(10_000n)
      await expect(bonded1).to.eq(10_000n)
      await expect(awaitingUnlock1).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(20_000n)
      expect(await nft.balanceOf(owner)).to.eq(1)

      await expect(nft.connect(user1).unbond(1n)).to.be.revertedWithCustomError(nft, 'ERC721InsufficientApproval')

      await nft.setApprovalForAll(user1, true)
      await nft.connect(user1).unbond(1n)

      const [locked2, bonded2, awaitingUnlock2] = await ft.lockedBalancesOf(owner)
      await expect(locked2).to.eq(0)
      await expect(bonded2).to.eq(0)
      await expect(awaitingUnlock2).to.eq(0)
      expect(await ft.balanceOf(owner)).to.eq(20_000n)
      expect(await nft.balanceOf(owner)).to.eq(0)
    })
  })

  describe('Transfer behavior', () => {
    it('Can transfer fungible tokens', async () => {
      const { owner, user1, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 20_000n)

      expect(await ft.balanceOf(owner)).to.eq(20_000n)
      expect(await ft.balanceOf(user1)).to.eq(0)

      await ft.transfer(user1, 10_000n)

      expect(await ft.balanceOf(owner)).to.eq(10_000n)
      expect(await ft.balanceOf(user1)).to.eq(10_000n)
    })

    it('Cannot transfer locked tokens', async () => {
      const { owner, user1, ft, nft } = await deployFixturesWithActiveTiers()
      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 19_000n)

      // lock up tokens and mint an NFT
      await ft.lock(10_000n)
      // dry lock additional tokens
      await ft.lockOnly(8_000n)
      // have some tokens awaitingUnlock tokens
      await ft.unlock(5_000n)

      expect(await ft.balanceOf(owner)).to.eq(19_000n)
      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      await expect(locked0).to.eq(18_000n)
      await expect(bonded0).to.eq(10_000n)
      await expect(awaitingUnlock0).to.eq(5_000n)
      expect(await nft.balanceOf(owner)).to.eq(1)
      expect(await ft.balanceOf(user1)).to.eq(0)
      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(user1)
      await expect(locked1).to.eq(0)
      await expect(bonded1).to.eq(0)
      await expect(awaitingUnlock1).to.eq(0)
      expect(await nft.balanceOf(user1)).to.eq(0)

      // transfering all tokens fails
      await expect(ft.transfer(user1, 19_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnlockedBalance')

      // transfering locked tokens fails
      await expect(ft.transfer(user1, 12_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnlockedBalance')

      // transfering locked tokens fails
      await expect(ft.transfer(user1, 8_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnlockedBalance')

      // transfering locked tokens fails
      await expect(ft.transfer(user1, 5_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnlockedBalance')

      // transfering locked tokens fails
      await expect(ft.transfer(user1, 2_000n)).to.be.revertedWithCustomError(ft, 'ERC20HInsufficientUnlockedBalance')

      // transfering unlocked tokens fails
      await ft.transfer(user1, 1_000n)

      expect(await ft.balanceOf(owner)).to.eq(18_000n)
      expect(await ft.balanceOf(user1)).to.eq(1_000n)

      expect(await ft.balanceOf(owner)).to.eq(18_000n)
      const [locked2, bonded2, awaitingUnlock2] = await ft.lockedBalancesOf(owner)
      await expect(locked2).to.eq(18_000n)
      await expect(bonded2).to.eq(10_000n)
      await expect(awaitingUnlock2).to.eq(5_000n)
      expect(await nft.balanceOf(owner)).to.eq(1)
      expect(await ft.balanceOf(user1)).to.eq(1_000n)
      const [locked3, bonded3, awaitingUnlock3] = await ft.lockedBalancesOf(user1)
      await expect(locked3).to.eq(0)
      await expect(bonded3).to.eq(0)
      await expect(awaitingUnlock3).to.eq(0)
      expect(await nft.balanceOf(user1)).to.eq(0)
    })

    it('Transferring NFT transfers the locked tokens', async () => {
      const { owner, user1, ft, nft } = await deployFixturesWithActiveTiers()
      const ownerAddress = await owner.getAddress()
      const user1Address = await user1.getAddress()

      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 19_000n)

      // lock up tokens and mint an NFT
      await ft.lock(10_000n)

      expect(await nft.ownerOf(0n)).to.eq(ownerAddress)

      expect(await ft.balanceOf(owner)).to.eq(19_000n)
      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      await expect(locked0).to.eq(10_000n)
      await expect(bonded0).to.eq(10_000n)
      await expect(awaitingUnlock0).to.eq(0)
      expect(await nft.balanceOf(owner)).to.eq(1)

      expect(await ft.balanceOf(user1)).to.eq(0)
      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(user1)
      await expect(locked1).to.eq(0)
      await expect(bonded1).to.eq(0)
      await expect(awaitingUnlock1).to.eq(0)
      expect(await nft.balanceOf(user1)).to.eq(0)

      // transfer nft
      await nft.safeTransferFrom(owner, user1, 0)

      expect(await nft.ownerOf(0n)).to.eq(user1Address)

      expect(await ft.balanceOf(owner)).to.eq(9_000n)
      const [locked2, bonded2, awaitingUnlock2] = await ft.lockedBalancesOf(owner)
      await expect(locked2).to.eq(0)
      await expect(bonded2).to.eq(0)
      await expect(awaitingUnlock2).to.eq(0)
      expect(await nft.balanceOf(owner)).to.eq(0)

      expect(await ft.balanceOf(user1)).to.eq(10_000n)
      const [locked3, bonded3, awaitingUnlock3] = await ft.lockedBalancesOf(user1)
      await expect(locked3).to.eq(10_000n)
      await expect(bonded3).to.eq(10_000n)
      await expect(awaitingUnlock3).to.eq(0)
      expect(await nft.balanceOf(user1)).to.eq(1)
    })

    it('Can only transfer other user tokens with approval', async () => {
      const { owner, user1, ft, nft } = await deployFixturesWithActiveTiers()
      const ownerAddress = await owner.getAddress()

      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 19_000n)

      await expect(ft.connect(user1).transferFrom(owner, user1, 19_000n)).to.be.revertedWithCustomError(
        ft,
        'ERC20InsufficientAllowance',
      )

      await ft.connect(owner).approve(user1, 1000n)

      await expect(ft.connect(user1).transferFrom(owner, user1, 19_000n)).to.be.revertedWithCustomError(
        ft,
        'ERC20InsufficientAllowance',
      )

      expect(await ft.balanceOf(user1)).to.eq(0)
      expect(await ft.allowance(owner, user1)).to.eq(1_000n)

      await ft.connect(user1).transferFrom(owner, user1, 900n)

      expect(await ft.balanceOf(user1)).to.eq(900n)
      expect(await ft.allowance(owner, user1)).to.eq(100n)
    })

    it('Can transfer NFT with approval', async () => {
      const { owner, user1, ft, nft } = await deployFixturesWithActiveTiers()
      const ownerAddress = await owner.getAddress()
      const user1Address = await user1.getAddress()
      await ft.setUnlockCooldown(1)

      await ft.mint(owner, 19_000n)
      await ft.lock(10_000n)
      expect(await nft.ownerOf(0n)).to.eq(ownerAddress)

      await expect(nft.connect(user1).transferFrom(owner, user1, 0n)).to.be.revertedWithCustomError(
        nft,
        'ERC721InsufficientApproval',
      )

      await nft.approve(user1, 0n)
      await nft.connect(user1).safeTransferFrom(owner, user1, 0n)

      expect(await ft.balanceOf(owner)).to.eq(9_000n)
      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      await expect(locked0).to.eq(0)
      await expect(bonded0).to.eq(0)
      await expect(awaitingUnlock0).to.eq(0)
      expect(await nft.balanceOf(owner)).to.eq(0)

      expect(await ft.balanceOf(user1)).to.eq(10_000n)
      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(user1)
      await expect(locked1).to.eq(10_000n)
      await expect(bonded1).to.eq(10_000n)
      await expect(awaitingUnlock1).to.eq(0)
      expect(await nft.balanceOf(user1)).to.eq(1)
      expect(await nft.ownerOf(0n)).to.eq(user1Address)
    })
  })

  describe('[OPTIONAL] Miscellaneous tests from custom add-ons', () => {
    it('[OPTIONAL] Should not bond another users tokens', async () => {
      const { owner, user1, ft, nft } = await deployFixturesWithActiveTiers()
      const ownerAddress = await owner.getAddress()

      await ft.mint(owner, 10_000n)
      await ft.lockOnly(10_000n)

      await expect(nft.connect(user1).bond(owner, 0n)).to.be.revertedWithCustomError(nft, 'ERC721InsufficientApproval')
    })

    it('[OPTIONAL] Should burn locked tokens if burning NFT', async () => {
      const { owner, user1, ft, nft } = await deployFixturesWithActiveTiers()
      const ownerAddress = await owner.getAddress()

      await ft.setUnlockCooldown(1)
      await ft.mint(owner, 19_000n)

      // lock up tokens and mint an NFT
      await ft.lock(10_000n)

      expect(await nft.ownerOf(0n)).to.eq(ownerAddress)
      expect(await nft.totalSupply()).to.eq(1)
      expect(await ft.totalSupply()).to.eq(19_000n)

      expect(await ft.balanceOf(owner)).to.eq(19_000n)
      const [locked0, bonded0, awaitingUnlock0] = await ft.lockedBalancesOf(owner)
      await expect(locked0).to.eq(10_000n)
      await expect(bonded0).to.eq(10_000n)
      await expect(awaitingUnlock0).to.eq(0)
      expect(await nft.balanceOf(owner)).to.eq(1)

      // burn nft
      await nft.burn(0)

      await expect(nft.ownerOf(0n)).to.be.revertedWithCustomError(nft, 'ERC721NonexistentToken')
      expect(await nft.totalSupply()).to.eq(0)
      expect(await ft.totalSupply()).to.eq(9_000n)

      expect(await ft.balanceOf(owner)).to.eq(9_000n)
      const [locked1, bonded1, awaitingUnlock1] = await ft.lockedBalancesOf(owner)
      await expect(locked1).to.eq(0)
      await expect(bonded1).to.eq(0)
      await expect(awaitingUnlock1).to.eq(0)
      expect(await nft.balanceOf(owner)).to.eq(0)
    })
  })
})
