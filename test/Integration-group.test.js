const { expect } = require("chai");
const { time } = require('@openzeppelin/test-helpers');
const { CATEGORY, timestampFromNow, getOfferHashBytes, signOffer } = require("./test-helpers");


describe("PWN", function () {

	let ERC20, ERC721, ERC1155;
	let NFT, WETH, DAI, GAME;
	let PWN, PWNDeed, PWNVault, PWNGroupOfferFactory, ContractWallet;
	let borrower, lender1, lender2, lender3, lender4, contractOwner;
	let addr1, addr2, addrs;

	const deedEventIface = new ethers.utils.Interface([
		"event GroupDeedCreated(uint256 indexed did, address indexed lender)",
	]);

	const lInitialDAI = 1000;
	const bInitialDAI = 200;
	const bInitialWETH = 100;
	const nonce = ethers.utils.solidityKeccak256([ "string" ], [ "nonce" ]);

	beforeEach(async function () {
		ERC20 = await ethers.getContractFactory("Basic20");
		ERC721 = await ethers.getContractFactory("Basic721");
		ERC1155 = await ethers.getContractFactory("Basic1155");

		PWN = await ethers.getContractFactory("PWN");
		PWNDeed = await ethers.getContractFactory("PWNDeed");
		PWNVault = await ethers.getContractFactory("PWNVault");
		ContractWallet = await ethers.getContractFactory("ContractWallet");

		[borrower, lender1, lender2, lender3, lender4, contractOwner, addr1, addr2, ...addrs] = await ethers.getSigners();

		WETH = await ERC20.deploy("Fake wETH", "WETH");
		DAI = await ERC20.deploy("Fake Dai", "DAI");
		NFT = await ERC721.deploy("Real NFT", "NFT");
		GAME = await ERC1155.deploy("https://pwn.finance/game/")

		PWNDeed = await PWNDeed.deploy("https://pwn.finance/");
		PWNVault = await PWNVault.deploy();
		PWN = await PWN.deploy(PWNDeed.address, PWNVault.address);
		ContractWallet = await ContractWallet.connect(contractOwner).deploy();

		await NFT.deployed();
		await DAI.deployed();
		await GAME.deployed();
		await PWNDeed.deployed();
		await PWNVault.deployed();
		await PWN.deployed();

		await PWNDeed.setPWN(PWN.address);
		await PWNVault.setPWN(PWN.address);

		await DAI.mint(lender1.address, lInitialDAI);
		await DAI.mint(lender2.address, lInitialDAI);
		await DAI.mint(lender3.address, lInitialDAI);
		await DAI.mint(lender4.address, lInitialDAI);
		await DAI.mint(ContractWallet.address, lInitialDAI);
		await DAI.mint(borrower.address, bInitialDAI);
		await WETH.mint(borrower.address, bInitialWETH);
		await NFT.mint(borrower.address, 42);
		await GAME.mint(borrower.address, 1337, 1, 0);
	});


	describe("Workflow - Group offer", function() {

		it("Should be possible to accept new group offer", async function() {
			// 1st lenders offer
			const groupOffer1 = [
				NFT.address, CATEGORY.ERC721, 0, 42,
				DAI.address, 1000, 200,
				3600, 0, 250, lender1.address, nonce,
			];
			const signature1 = await signOffer(groupOffer1, PWNDeed.address, lender1);
			await DAI.connect(lender1).approve(PWNVault.address, 250);

			// 2nd lenders offer
			const groupOffer2 = [
				NFT.address, CATEGORY.ERC721, 0, 42,
				DAI.address, 1000, 200,
				3600, 0, 400, lender2.address, nonce,
			];
			const signature2 = await signOffer(groupOffer2, PWNDeed.address, lender2);
			await DAI.connect(lender2).approve(PWNVault.address, 400);

			// 3rd lenders offer
			const groupOffer3 = [
				NFT.address, CATEGORY.ERC721, 0, 42,
				DAI.address, 1000, 200,
				3600, 0, 300, lender3.address, nonce,
			];
			const signature3 = await signOffer(groupOffer3, PWNDeed.address, lender3);
			await DAI.connect(lender3).approve(PWNVault.address, 300);

			// 4th lenders offer
			const groupOffer4 = [
				NFT.address, CATEGORY.ERC721, 0, 42,
				DAI.address, 1000, 200,
				3600, 0, 50, lender4.address, nonce,
			];
			const signature4 = await signOffer(groupOffer4, PWNDeed.address, lender4);
			await DAI.connect(lender4).approve(PWNVault.address, 50);

			// Allow Vault to transfer collateral
			await NFT.connect(borrower).approve(PWNVault.address, 42);

			// Deploy group offer contract
			const tx = await PWN.connect(borrower).createDeedGroup(
				[
					NFT.address, CATEGORY.ERC721, 0, 42,
					DAI.address, 1000, 200, 3600,
				],
				[
					[ 0, 250, lender1.address, nonce, signature1 ],
					[ 0, 400, lender2.address, nonce, signature2 ],
					[ 0, 300, lender3.address, nonce, signature3 ],
					[ 0, 50,  lender4.address, nonce, signature4 ],
				],
			);
			const response = await tx.wait();
			const logDescription = deedEventIface.parseLog(response.logs[2]);
			const groupOfferContractAddress = logDescription.args.lender;
			const did = logDescription.args.did;

			expect(await PWNDeed.balanceOf(groupOfferContractAddress, did)).to.equal(1);
			expect(await NFT.ownerOf(42)).to.equal(PWNVault.address);
			expect(await DAI.balanceOf(borrower.address)).to.equal(bInitialDAI + 1000);
		});

	});

});
